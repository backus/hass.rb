require 'http'
require 'concord'
require 'anima'
require 'slop'

class HA
  class API
    include Concord.new(:server, :token)

    # Fetch HASS_TOKEN from env
    def self.from_env(_env)
      server = ENV.fetch('HASS_SERVER')
      token = ENV.fetch('HASS_TOKEN')
      new(server, token)
    end

    def list_shades
      response = HTTP.headers('Authorization' => "Bearer #{token}")
                     .get("#{server}/api/states")

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
      response = HTTP.headers('Authorization' => "Bearer #{token}")
                     .post("#{server}/api/services/cover/#{state}_cover",
                           json: { entity_id: entity_id })

      raise "Error: #{response.code} - #{response.body}" if response.code != 200

      puts "#{state.capitalize}ing #{entity_id}..."
    end
  end

  class CLI
    # Parse positional command and subcommand then delegate the the subcommand's CLI parser
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
        Command::Shades.parse_cli(argv.drop(1), api: API.from_env(ENV)).run
      when 'help'
        puts usage
      else
        puts usage
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

      class Open < self
        include anima.add(:entity)

        def self.parse_cli(argv, api:)
          parser = Slop.parse(argv) do |o|
            o.banner = 'Usage: ha shades open <entity>'
            o.separator ''
            o.separator 'Options:'
            o.bool '-a', '--all', 'Open all shades', default: false
          end

          opts = parser.to_h

          entity =
            if opts.fetch(:all)
              'all'
            else
              parser.arguments[0]
            end

          new(entity: entity, api: api)
        end

        def run
          api.open_shade(entity)
        end
      end

      class Close < self
        include anima.add(:entity)

        def self.parse_cli(argv, api:)
          parser = Slop.parse(argv) do |o|
            o.banner = 'Usage: ha shades close <entity>'
            o.separator ''
            o.separator 'Options:'
            o.bool '-a', '--all', 'Close all shades', default: false
          end

          opts = parser.to_h

          entity =
            if opts.fetch(:all)
              'all'
            else
              parser.arguments[0]
            end

          new(entity: entity, api: api)
        end

        def run
          api.close_shade(entity)
        end
      end

      class All < self
        def run
          api.list_shades.each do |entity|
            api.open_shade(entity)
          end
        end
      end
    end
  end
end
