# frozen_string_literal: true

require 'socket'
require 'logger'

require 'http'
require 'concord'
require 'anima'
require 'memoizable'
require 'slop'
require 'websocket/driver'

Thread.abort_on_exception = true

class HA
  singleton_class.attr_reader :logger

  def self.setup_logger!
    ha_logger = Logger.new($stderr)

    ha_logger.formatter = proc do |severity, datetime, _, msg|
      time = datetime.strftime('%-l:%M %p') # Example: 2:25 PM
      "#{time} [#{severity}] -- #{msg}\n"
    end

    ha_logger.level = Logger::INFO

    @logger = ha_logger
  end

  setup_logger!

  class API
    include Concord.new(:server, :token)
    include Memoizable

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

    def list_entity_registry
      ws.call('config/entity_registry/list')
    end

    def ws
      @ws ||= WebSocketAPI.new(server, token)
    end

    private

    def change_shade_state(entity_id, state:)
      post("/api/services/cover/#{state}_cover", json: { entity_id: })
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

    class WebSocketAPI
      include Concord.new(:socket, :token)

      InvalidAuth = Class.new(StandardError)

      def initialize(http_host, token)
        super(WS.new(http_host), token)

        self.request_counter = 0

        authenticate
      end

      def authenticate
        response = request(type: 'auth', access_token: token)
        response = socket.pop_inbox if response.fetch(:type) == 'auth_required'

        raise InvalidAuth, response.fetch(:message) if response.fetch(:type) == 'auth_invalid'
      end

      def call(type, **kwargs)
        self.request_counter += 1

        request(type:, id: request_counter, **kwargs)
      end

      private

      def request(**payload)
        socket.send_json(payload)
        socket.pop_inbox
      end

      attr_accessor :request_counter
    end

    class WS
      include Anima.new(:driver, :socket, :inbox)

      SOCKET_STATES = %i[uninitialized open closed].freeze

      private :driver
      private :socket

      def initialize(http_host)
        host = Addressable::URI.parse(http_host)
        socket = SocketDriver.new(host)
        driver = WebSocket::Driver.client(socket)

        self.state  = :uninitialized
        self.thread = nil

        super(socket:, driver:, inbox: Queue.new)

        setup_driver!
      end

      def send_text(text)
        driver.text(text)
      end

      def send_json(payload)
        send_text(JSON.dump(payload))
      end

      def _socket
        socket
      end

      def pop_inbox
        inbox.pop
      end

      private

      attr_accessor :state, :thread

      def state_is?(given_state)
        validate_state!(given_state)

        state == given_state
      end

      def update_state(given_state)
        validate_state!(given_state)

        HA.logger.debug("Transitioning WS state from #{state} to #{given_state}")

        self.state = given_state
      end

      def validate_state!(given_state)
        raise "Invalid state: #{given_state}" unless SOCKET_STATES.include?(given_state)
      end

      def handle_server_reply(event)
        response_payload = JSON.parse(event.data, symbolize_names: true)
        inbox.push(response_payload)
      end

      def handle_close(event)
        update_state(:closed)
        HA.logger.debug("WS connection closed: #{event.inspect}")
      end

      def handle_open(event)
        update_state(:open)
        HA.logger.debug("WS connection opened #{event}")
      end

      def setup_driver!
        register_driver_handler(:open, :handle_open)
        register_driver_handler(:message, :handle_server_reply)
        register_driver_handler(:close, :handle_close)

        create_listener_thread!

        driver.start
      end

      def register_driver_handler(driver_event, handler_method_name)
        driver.on(driver_event, &method(handler_method_name))
      end

      def create_listener_thread!
        raise 'Listener thread already exists' if thread

        HA.logger.debug('Creating WS listener thread')

        client = self

        self.thread = Thread.new do
          driver.parse(client._socket.read) until state_is?(:closed)
        end
      end

      class SocketDriver
        include Concord.new(:host, :tcp_socket)

        ENDPOINT = '/api/websocket'

        def initialize(host)
          tcp_socket = TCPSocket.new(host.host, host.port)

          super(host, tcp_socket)
        end

        def url
          "ws://#{host.host}:#{host.port}#{ENDPOINT}"
        end

        def write(packet)
          HA.logger.debug("Sending WS packet: #{packet}")

          tcp_socket.write(packet)
        end

        def read
          tcp_socket.readpartial(4096)
        end
      end
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
          List.new(api:)
        when 'open'
          Open.parse_cli(sub_argv, api:)
        when 'close'
          Close.parse_cli(sub_argv, api:)
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

          new(entities:, api:)
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
