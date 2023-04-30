# frozen_string_literal: true

require 'http'
require 'concord'
require 'anima'
require 'slop'

class HA
  class API
    include Concord.new(:server, :token)

    def self.from_env(env)
      server = env.fetch('HASS_SERVER')
      token = env.fetch('HASS_TOKEN')
      new(server, token)
    end

    def list_shades
      response = get('/api/states')
      response.parse.select { |s| s['attributes']['device_class'] == 'shade' }
              .map { |s| s['entity_id'] }
    end

    def open_shade(entity_id)
      change_shade_state(entity_id, state: 'open')
    end

    def close_shade(entity_id)
      change_shade_state(entity_id, state: 'close')
    end

    private

    def change_shade_state(entity_id, state:)
      post("/api/services/cover/#{state}_cover", json: { entity_id: entity_id })
    end

    def get(path)
      unwrap_response(http.get(route(path)))
    end

    def post(path, options)
      unwrap_response(http.post(route(path), options))
    end

    def unwrap_response(response)
      return response if response.status.success?

      raise "Error: #{response.status} - #{response.body}"
    end

    def http
      HTTP.headers('Authorization' => "Bearer #{token}")
    end

    def route(path)
      "#{server}#{path}"
    end
  end

  class CLI
    def self.parse(argv)
      usage = <<~USAGE
        Usage: ha <command> [options]

        Commands:
            shades - Open / Close shades
            help   - List commands

        You can also do `ha <command> --help` for more information on a specific command
      USAGE

      case argv[0]
      when 'shades'
        Command::Shades.parse_cli(argv.drop(1), api: API.from_env(ENV))
      when 'help'
        puts usage
        exit 0
      else
        puts usage
        exit 1
      end
    end
  end

  class Command
    include Anima.new(:api)
    include AbstractType

    class Shades < self
      def self.parse_cli(argv, api:)
        usage = <<~USAGE
          Usage: ha shades <command> [options]

          Commands:

              list  - List shades
              open  - Open shade
              close - Close shade
        USAGE

        subcommand = argv[0]
        sub_argv = argv.drop(1)

        case subcommand
        when 'list'
          List.new(api: api)
        when 'open'
          Open.parse_cli(sub_argv, api: api)
        when 'close'
          Close.parse_cli(sub_argv, api: api)
        else
          puts "Error: Unknown command #{subcommand}"
          puts usage
          exit(1)
        end
      end

      class List < self
        def run
          api.list_shades.each { |s| puts s }
        end
      end

      class OpenClose < self
        include AbstractType

        def self.parse_cli(argv, api:)
          parser = Slop.parse(argv) do |o|
            o.banner = "Usage: ha shades #{self::ACTION} [entity1] [entity2] ..."
            o.separator ''
            o.separator 'Options:'
            o.bool '-a', '--all', "#{self::ACTION.capitalize} all shades", default: false
          end

          opts = parser.to_h

          if opts.fetch(:all) && !parser.arguments.empty?
            puts 'Error: --all and individual entities are mutually exclusive'
            puts parser.to_s
            exit(1)
          end

          if !opts.fetch(:all) && parser.arguments.empty?
            puts 'Error: Provide either --all or at least one entity ID'
            puts parser.to_s
            exit(1)
          end

          entities =
            if opts.fetch(:all)
              api.list_shades
            else
              parser.arguments
            end

          new(entities: entities, api: api)
        end
      end

      class Open < OpenClose
        include anima.add(:entities)

        ACTION = 'open'

        def run
          entities.each do |entity|
            puts "Opening #{entity}..."
            api.open_shade(entity)
          end
        end
      end

      class Close < OpenClose
        include anima.add(:entities)

        ACTION = 'close'

        def run
          entities.each do |entity|
            puts "Closinging #{entity}..."
            api.close_shade(entity)
          end
        end
      end
    end
  end
end
