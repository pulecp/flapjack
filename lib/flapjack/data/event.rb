#!/usr/bin/env ruby

require 'oj'
require 'flapjack/redis_proxy'

require 'flapjack/data/check'

module Flapjack
  module Data
    class Event

      attr_accessor :counter, :id_hash

      attr_reader :id, :summary, :details, :acknowledgement_id, :perfdata

      # type was a required key in v1, but is superfluous
      REQUIRED_KEYS = %w(state entity check summary)
      OPTIONAL_KEYS = %w(time details acknowledgement_id duration tags perfdata type)

      VALIDATIONS = {
        proc {|e| e['state'].is_a?(String) &&
            ['ok', 'warning', 'critical', 'unknown', 'acknowledgement',
             'test_notifications'].include?(e['state'].downcase) } =>
          "state must be one of 'ok', 'warning', 'critical', 'unknown', " +
          "'acknowledgement' or 'test_notifications'",

        proc {|e| e['entity'].is_a?(String) } =>
          "entity must be a string",

        proc {|e| e['check'].is_a?(String) } =>
          "check must be a string",

        proc {|e| e['summary'].is_a?(String) } =>
          "summary must be a string",

        proc {|e| e['time'].nil? ||
                  e['time'].is_a?(Integer) ||
                 (e['time'].is_a?(String) && !!(e['time'] =~ /^\d+$/)) } =>
          "time must be a positive integer, or a string castable to one",

        proc {|e| e['details'].nil? || e['details'].is_a?(String) } =>
          "details must be a string",

        proc { |e| e['perfdata'].nil? || e['perfdata'].is_a?(String) } =>
          "perfdata must be a string",

        proc {|e| e['acknowledgement_id'].nil? ||
                  e['acknowledgement_id'].is_a?(String) ||
                  e['acknowledgement_id'].is_a?(Integer) } =>
          "acknowledgement_id must be a string or an integer",

        proc {|e| e['duration'].nil? ||
                  e['duration'].is_a?(Integer) ||
                 (e['duration'].is_a?(String) && !!(e['duration'] =~ /^\d+$/)) } =>
          "duration must be a positive integer, or a string castable to one",

        proc {|e| e['tags'].nil? ||
                 (e['tags'].is_a?(Array) &&
                  e['tags'].all? {|tag| tag.is_a?(String)}) } =>
          "tags must be an array of strings",
      }

      def self.parse_and_validate(raw, opts = {})
        errors = []
        if parsed = Flapjack.load_json(raw)
          if parsed.is_a?(Hash)
            errors = validation_errors_for_hash(parsed, opts)
          else
            errors << "Event must be a JSON hash, see http://flapjack.io/docs/1.0/development/DATA_STRUCTURES#event-queue"
          end
          return [parsed, errors]
        end
        [nil, errors]
      rescue Oj::Error => e
        errors << "Error deserialising event json: #{e}, raw json: #{raw.inspect}"
        [nil, errors]
      end

      def self.validation_errors_for_hash(hash, opts = {})
        errors = []
        missing_keys = REQUIRED_KEYS.select {|k|
          !hash.has_key?(k) || hash[k].nil? || hash[k].empty?
        }
        unless missing_keys.empty?
          errors << "Event hash has missing keys '#{missing_keys.join('\', \'')}'"
        end

        unknown_keys =  hash.keys - (REQUIRED_KEYS + OPTIONAL_KEYS)
        unless unknown_keys.empty?
          errors << "Event hash has unknown key(s) '#{unknown_keys.join('\', \'')}'"
        end

        if errors.empty?
          errors += VALIDATIONS.keys.inject([]) {|ret,vk|
            ret << "Event #{VALIDATIONS[vk]}" unless vk.call(hash)
            ret
          }
        end
        errors
      end

      # creates, or modifies, an event object and adds it to the events list in redis
      #   'entity'    => entity_name,
      #   'check'     => check_name,
      #   'state'     => state,
      #   'summary'   => check_output,
      #   'details'   => check_long_output,
      #   'perfdata'  => perf_data,
      #   'time'      => timestamp
      def self.push(queue, event)
        event['time'] = Time.now.to_i if event['time'].nil?

        begin
          event_json = Flapjack.dump_json(event)
        rescue Oj::Error => e
          Flapjack.logger.warn("Error serialising event json: #{e}, event: #{event.inspect}")
          event_json = nil
        end

        if event_json
          Flapjack.redis.multi do
            Flapjack.redis.lpush(queue, event_json)
            Flapjack.redis.lpush("#{queue}_actions", "+")
          end
        end
      end

      # Provide a count of the number of events on the queue to be processed.
      def self.pending_count(queue)
        Flapjack.redis.llen(queue)
      end

      def self.create_acknowledgements(queue, checks, opts = {})
        raise "Check(s) must be provided" if checks.nil?
        checks = [checks] unless checks.is_a?(Array)
        checks.each do |check|
          self.push(queue, 'state'              => 'acknowledgement',
                           'check'              => check.name,
                           'summary'            => opts[:summary],
                           'duration'           => opts[:duration],
                           'acknowledgement_id' => opts[:acknowledgement_id])
        end
      end

      def self.test_notifications(queue, checks, opts = {})
        raise "Check(s) must be provided" if checks.nil?
        checks = [checks] unless checks.is_a?(Array)
        checks.each do |check|
          self.push(queue, 'state'              => 'test_notifications',
                           'check'              => check.name,
                           'summary'            => opts[:summary],
                           'details'            => opts[:details])
        end
      end

      def initialize(attrs = {})
        @id = "#{attrs['entity']}:#{attrs['check']}"
        [:state, :time, :summary, :perfdata, :details, :acknowledgement_id,
         :duration].each do |key|
          instance_variable_set("@#{key.to_s}", attrs[key.to_s])
        end
        # details and perfdata are optional. set to nil if they only contain whitespace
        @details = (@details.is_a?(String) && ! @details.strip.empty?) ? @details.strip : nil
        @perfdata = (@perfdata.is_a?(String) && ! @perfdata.strip.empty?) ? @perfdata.strip : nil
      end

      def state
        return unless @state
        @state.downcase
      end

      def duration
        return unless @duration
        @duration.to_i
      end

      def time
        return unless @time
        @time.to_i
      end

      def dump
        return @dump unless @dump.nil?
        @dump = "#{id}, #{state}, #{summary}"
        @dump << ", #{Time.at(time).to_s}" unless time.nil?
      end
    end
  end
end

