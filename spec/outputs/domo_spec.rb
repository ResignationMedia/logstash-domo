# encoding: utf-8
require "java"
require "logstash/devutils/rspec/spec_helper"
require "domo/queue"
require "domo/queue/redis"
require "logstash/event"
require "core_extensions/flatten"
require "rake"
require_relative "../../spec/domo_spec_helper"

shared_context "dataset bootstrap" do
  let!(:test_settings) { get_test_settings }
  let!(:domo_client) { get_domo_client(test_settings) }
  let(:stream_config) { bootstrap_dataset(domo_client) }
end

shared_context "events" do
  let!(:events) do
    (1..5).map do |i|
      cur_date = Date.today.to_s
      LogStash::Event.new("Count" => i,
                          "Event Name" => "event_#{i}",
                          "Event Timestamp" => LogStash::Timestamp.now,
                          "Event Date" => cur_date,
                          "Percent" => ((i.to_f/5)*100).round(2))
    end
  end
  let!(:mistyped_event) do
    LogStash::Event.new("Count" => 1,
                        "Event Name" => "",
                        "Event Timestamp" => LogStash::Timestamp.now,
                        "Event Date" => "fz",
                        "Percent" => 2)
  end
  let!(:nil_event) do
    LogStash::Event.new("Count" => nil,
                        "Event Name" => "nil_event",
                        "Event Timestamp" => LogStash::Timestamp.now,
                        "Event Date" => nil,
                        "Percent" => nil)
  end
end

describe CoreExtensions, extensions: true do
  subject do
    LogStash::Event.new("venue_id"=>8186, "index"=>"atv", "subscription_id"=>3083,
                        "array_val"=>[0, 1],
                        "geoip"=>{"country_name"=>"United States", "dma_code"=>635, "country_code2"=>"US", "region_name"=>"Texas", "city_name"=>"Austin", "country_code3"=>"US", "latitude"=>30.2414, "postal_code"=>"78704", "region_code"=>"TX",
                                  "location"=>{"lon"=>-97.7687, "lat"=>30.2414}, "timezone"=>"America/Chicago", "continent_code"=>"NA", "longitude"=>-97.7687, "ip"=>"71.42.223.130"},
                        "client"=>"Roku", "@timestamp"=>"2018-12-27T19:01:01.000Z", "event"=>"channel.playback", "customer_type"=>"business", "date"=>1545937261, "organization_id"=>3193, "@version"=>"1", "device_id"=>5729, "ip"=>"71.42.223.130")
  end

  before(:each) { Hash.include CoreExtensions::Flatten }

  it "properly flattens complex events", :data_structure => true do
    flattened_event = subject.to_hash.flatten_with_path
    expect(flattened_event).not_to eq(subject)
    expect(flattened_event).to be_a(Hash)
    expect(flattened_event).not_to satisfy("not have sub-hashes") { |v| v.any? { |k, v| v.is_a? Hash } }
  end
end

describe "rake tasks", rake: true do
  include_context "dataset bootstrap" do
    let(:test_settings) { get_test_settings }
    let(:domo_client) { get_domo_client(test_settings) }
    let(:stream_config) { bootstrap_dataset(domo_client, "_BATCH_DATE_") }
  end

  let(:config) do
    global_config.clone.merge(
        {
            "upload_timestamp_field" => "_BATCH_DATE_",
        }
    )
  end

  let!(:tasks_path) do
    File.expand_path(File.join(File.dirname(File.dirname(File.dirname(__FILE__ ))), "rakelib"))
  end

  let(:redis_client) do
    redis_client = {:url => ENV["REDIS_URL"]}
    redis_client[:sentinels] = ENV.select { |k, v| k.start_with? "REDIS_SENTINEL_HOST"}.map do |k, v|
      index = k.split("_")[-1].to_i
      port = ENV.fetch("REDIS_SENTINEL_PORT_#{index}", 26379)

      {
          :host => v,
          :port => port,
      }
    end

    if redis_client[:sentinels].length <= 0
      redis_client = redis_client.reject { |k, v| k == :sentinels }
    end

    Redis.new(redis_client)
  end

  let(:jobs) do
    events = (1..10).map do |i|
      {
          "Event Name"      => i.to_s,
          "Count"           => i,
          "Event Timestamp" => Time.now.utc.to_datetime,
          "Event Date"      => Time.now.utc.to_date,
          "Percent"         => ((i.to_f/10)*100).round(2),
          "_BATCH_DATE_"    => Time.now.utc.to_date
      }
    end

    csv_encode_opts = {
        :headers => events[0].keys,
        :write_headers => false,
        :return_headers => false,
    }
    events.map do |e|
      csv_data = CSV.generate(String.new, csv_encode_opts) do |csv_obj|
        data = e.sort_by { |k, _| events[0].key(k) }.to_h
        csv_obj << data.values
      end
      csv_data = [csv_data.strip]
      Domo::Queue::Job.new(csv_data)
    end
  end

  let(:old_dataset) { stream_config }
  let(:new_dataset) { bootstrap_dataset(domo_client, "_BATCH_DATE_") }
  let(:lib_root) { File.expand_path(File.dirname(File.dirname(File.dirname(__FILE__ )))) }
  let(:rake) { Rake::Application.new }
  subject { Rake::Task[task_name] }

  before(:each) do
    rake_filename = task_name.split(':').last
    loaded_files = $".reject {|file| file == File.join(tasks_path, "#{rake_filename}.rake").to_s }
    rake.rake_require(rake_filename, [tasks_path], loaded_files)
  end

  context "when the task is domo:migrate_queue" do
    let(:task_name) { "domo:migrate_queue" }
    let!(:old_queue) { Domo::Queue::Redis::JobQueue.active_queue(redis_client, old_dataset['dataset_id'], old_dataset['stream_id'], 'main') }
    let!(:new_queue) { Domo::Queue::Redis::JobQueue.active_queue(redis_client, new_dataset['dataset_id'], new_dataset['stream_id'], 'main') }
    let!(:task_args) { [old_dataset["dataset_id"], old_dataset["stream_id"], new_dataset["dataset_id"], new_dataset["stream_id"], true] }

    before(:each) do
      # Load the queue up with our jobs
      jobs.each do |job|
        old_queue << job
      end
    end

    after(:each) do |example|
      # Make sure the queues are clear
      old_queue.clear
      new_queue.clear
      # Re-enable the rake task for subsequent tests
      subject.reenable
    end

    it "moves everything from the old queue to the new queue" do
      expect(old_queue.length).to eq(10)
      expect(new_queue.length).to eq(0)

      subject.invoke(*task_args)
      expect(old_queue.length).to eq(0)
      expect(new_queue.length).to eq(10)
    end

    it "moves failed and pending jobs to the new queue" do
      old_queue.failures << jobs[0]

      pending_data = old_queue.pop.data
      old_queue.pending_jobs << [pending_data, pending_data]

      expect(old_queue.length).to eq(9)
      expect(old_queue.failures.length).to eq(1)
      expect(old_queue.pending_jobs.length).to eq(2)

      subject.invoke(*task_args)

      expect(old_queue.length).to eq(0)
      expect(old_queue.pending_jobs.length).to eq(0)
      expect(old_queue.all_empty?).to be(true)

      expect(new_queue.length).to eq(11)
      data_rows = Array.new
      new_queue.each_with_index do |job, i|
        expect(job.data.length).to be >= 1
        data_rows += job.data
      end

      expect(data_rows.length).to eq(12)
    end
  end

  after(:each) do |example|
    if example.exception
      puts "Example #{example} failed."
    end
    unless ENV.fetch("KEEP_FAILED_DATASETS", false)
      domo_client.dataSetClient.delete(old_dataset["dataset_id"])
      domo_client.dataSetClient.delete(new_dataset["dataset_id"])
    end
  end
end
