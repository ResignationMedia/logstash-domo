require "java"
require "logstash-domo_jars.rb"

java_import "com.domo.sdk.streams.model.Stream"

def init_redis_client(settings=nil)
  if settings.nil?
    redis_client = { :url => ENV["REDIS_URL"] }
    redis_client[:sentinels] = ENV.select { |k, v| k.start_with? "REDIS_SENTINEL_HOST" }.map do |k, v|
      index = k.split("_")[-1].to_i
      port = ENV.fetch("REDIS_SENTINEL_PORT_#{index}", 26379)

      {
        :host => v,
        :port => port
      }
    end

    redis_client = redis_client.reject { |k, _| k == :sentinels } if redis_client[:sentinels].length <= 0
  else
    redis_client = settings['redis'].inject({}) {|memo, (k, v)| memo[k.to_sym] = v; memo}
  end

  Redis.new(redis_client)
end

def validate_settings!(settings, args)
  raise KeyError, 'domo' unless settings.key?('domo')
  raise ArgumentError, 'The old_dataset_id argument is required' if args.old_dataset_id.nil?
  raise ArgumentError, 'The new_dataset_id argument is required' if args.new_dataset_id.nil?
end

namespace :domo do
  desc 'Migrate logstash-output-domo queue from one Domo Dataset to another.'
  task :migrate_queue, [:old_dataset_id, :old_stream_id, :new_dataset_id, :new_stream_id, :quiet, :queue_settings] do |t, args|
    $LOAD_PATH.unshift(File.join(File.dirname(__dir__), "lib"))
    require "redis"
    require "yaml"
    require "logstash-domo/client"
    require "logstash-domo/queue/redis"

    args.with_defaults(:queue_settings => './testing/rspec_settings.yaml', :quiet => false)

    config_file = File.expand_path(args.queue_settings)
    begin
      settings = YAML.safe_load(File.read(config_file))
      validate_settings!(settings, args)

      # If this is set to nil, then the settings will be read from the the system environment
      # Otherwise it will be read from the settings.yaml file
      redis_settings = settings.fetch('redis', nil).nil? ? nil : settings
      redis_client = init_redis_client(redis_settings)

      domo_settings = settings['domo']
      domo_client = LogstashDomo::Client.new(domo_settings['client_id'],
                                             domo_settings['client_secret'],
                                             domo_settings.fetch('api_host', 'api.domo.com'),
                                             true,
                                             Java::ComDomoSdkRequest::Scope::DATA)

      old_dataset = {
          :dataset_id => args.old_dataset_id,
          :stream_id  => Integer(args.old_stream_id)
      }
      new_dataset = {
          :dataset_id => args.new_dataset_id,
          :stream_id  => Integer(args.new_stream_id)
      }
      # Somebody please explain to me why Rubocop thinks this is best practice styling. #EverybodyJustUsePythonPlease
      args.quiet = if !!args.quiet
                     args.quiet
                   elsif args.quiet == 'true'
                     true
                   else
                     false
                   end
    rescue KeyError => e
      puts "#{e} was not found in the settings file #{args.queue_settings}"
      exit(1)
    rescue ArgumentError => e
      puts e
      exit(1)
    end

    begin
      _ = domo_client.dataset(old_dataset[:dataset_id])
    rescue Java::ComDomoSdkRequest::RequestException => e
      puts "Error loading Dataset ID #{old_dataset[:dataset_id]}"
      raise e
    end
    begin
      _ = domo_client.dataset(new_dataset[:dataset_id])
    rescue Java::ComDomoSdkRequest::RequestException => e
      puts "Error loading Dataset ID #{new_dataset[:dataset_id]}"
      raise e
    end

    begin
      old_stream = domo_client.stream(old_dataset[:stream_id], old_dataset[:dataset_id], false )
      new_stream = domo_client.stream(new_dataset[:stream_id], new_dataset[:dataset_id], false )
    rescue Java::ComDomoSdkRequest::RequestException => e
      puts "Error locating Streams!"
      puts e
      raise e
    end

    old_queue = LogstashDomo::Queue::Redis::JobQueue.active_queue(redis_client, old_dataset[:dataset_id], old_stream.getId, 'main')
    old_queue.processing_status = :open
    old_queue.commit_status = :open

    new_queue = LogstashDomo::Queue::Redis::JobQueue.active_queue(redis_client, new_dataset[:dataset_id], new_stream.getId, 'main')
    new_queue.processing_status = :open
    new_queue.commit_status = :open

    num_old_jobs = old_queue.length + old_queue.failures.length
    old_pending_data = old_queue.pending_jobs.length

    until old_queue.processed?(true)
      old_queue.failures.reprocess_jobs!

      merged_data = []
      while old_queue.pending_jobs.merge_ready?(0, 0)
        merged_data = old_queue.pending_jobs.reduce(merged_data, 0)
        break if merged_data.length == 0

      end
      new_queue << LogstashDomo::Queue::Job.new(merged_data, 0) unless merged_data.length <= 0

      job = old_queue.pop

      unless job.nil?
        job.data_part = nil
        new_queue << job
      end

      old_queue.processing_status = :open
    end

    unless args.quiet
      puts "Successfully migrated #{num_old_jobs} jobs from #{old_dataset[:dataset_id]} to #{new_dataset[:dataset_id]}"
      puts "Successfully migrated #{old_pending_data} rows from the pending queue to #{new_dataset[:dataset_id]}"
    end
  end
end
