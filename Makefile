.PHONY: docker-test test redlock-test thread-test rake-test distclean clean build libbuild

default : test

ifdef RSPEC_TAGS
TAGS = $(shell tags=""; for t in $(RSPEC_TAGS); do tags="$${tags} --tag $$t"; done; echo "$$tags")
else
TAGS =
endif

ifdef RSPEC_ARGS
ARGS = $(shell args=""; for a in $(RSPEC_ARGS); do args="$${args} --$$a"; done; echo "$$args")
else
ARGS =
endif

ifdef KEEP_FAILED_DATASETS
RUN_ARGS = -e KEEP_FAILED_DATASETS=1
else
RUN_ARGS =
endif

test : clean
	-docker-compose run $(RUN_ARGS) --rm test bundle exec rspec --backtrace --format documentation$(ARGS)$(TAGS)
	docker-compose down

rake-test : clean
	-docker-compose run $(RUN_ARGS)--rm test bundle exec rspec --backtrace --format documentation$(ARGS) --tag rake$(TAGS)
	docker-compose down

distclean : clean
	-rm -rf vendor

clean :
	docker-compose down

build :
	bundle update
	docker-compose build

libbuild :
	gradle wrapper
	./gradlew vendor
	bundle install
