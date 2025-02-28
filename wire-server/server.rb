require 'timeout'
require 'socket'
require 'cucumber/wire/data_packet'
require 'cucumber/wire/connection'
require 'cucumber/wire/configuration'
require 'serialport'
require 'json'

# Patch 
class WireConnectionWithSocket < Cucumber::Wire::Connection
    def initialize(socket)
        # FIXME We might want to be able to pass in the timeouts to use
        config = Cucumber::Wire::Configuration.new({ host: socket.remote_address.ip_address, port: socket.remote_address.ip_port })
        super(config)
        @socket = socket
    end

    def recv_packet(handler)
        begin
            response = fetch_data_from_socket(@config.timeout('invoke'))
            puts response.to_json
            reply = response.handle_with(handler)
            if reply
                send_data_to_socket(reply.to_json)
            end
        rescue Timeout::Error => e
            backtrace = e.backtrace ; backtrace.shift # because Timeout puts some wierd stuff in there
            raise Timeout::Error, "Timed out calling wire server with message '#{message}'", backtrace
        end
    end
end

class RequestHandler
    def initialize(serial_port, steps, connection = nil, registry = nil)
        @connection = connection
        @message = underscore(self.class.name.split('::').last)
        @registry = registry
        # Should this be spun out into a class that the
        # user provides, that handles begin/end scenario and matching steps?
        @serial_port = serial_port
        @serial_connection = nil
        @steps = steps
    end

    def execute(request_params = nil)
        @connection.call_remote(self, @message, request_params)
    end

    def handle_fail(params)
        raise @connection.exception(params)
    end

    def handle_step_matches(params)
        puts "handle_step_matches"

        matched = nil
        matched_step_id = nil
        name_to_match = params['name_to_match']

        @steps.keys.each do |k|
            # The step might have parameters
            sqre = k.to_s.gsub("{string}", "'(.+)'")
            dqre = k.to_s.gsub("{string}", "\"(.+)\"")
            # Match the whole step, not just part of it
            sqre = "^#{sqre}$"
            dqre = "^#{dqre}$"
            matched = (name_to_match.match(sqre) or name_to_match.match(dqre))
            # This won't cope with steps defined with both single- and double-quotes
            # but folk shouldn't mix and match them ;-)
            if matched
                matched_step_id = @steps[k]
                break
            end
        end
        if matched
            match_params = { "id": matched_step_id, "args": [] }
            ma = matched.to_a
            # Get rid of the first match, as that's the full string
            ma.shift
            # Now we're left with just the parameters for the step
            ma.each do |arg|
                match_params[:args].push({ "val": arg, "pos": name_to_match.index(arg) })
            end
            puts "Matched step"
            puts match_params
            Cucumber::Wire::DataPacket.new("success", params = [match_params])
        else
            # The request succeeded, but didn't find anything
            Cucumber::Wire::DataPacket.new("success", params= [])
        end
    end

    def handle_begin_scenario(params)
        @serial_connection = SerialPort.open(@serial_port, 115200)
        if @serial_connection
            Cucumber::Wire::DataPacket.new("success")
        else
            Cucumber::Wire::DataPacket.new("fail", params = {"message": "Failed to open serial port"})
        end
    end

    def handle_end_scenario(params)
        @serial_connection.close if @serial_connection
        @serial_connection = nil
        Cucumber::Wire::DataPacket.new("success")
    end

    def handle_snippet_text(params)
        puts "skipping snippet_text"
        puts params
        # FIXME Include the snippet instructions to add steps here
        Cucumber::Wire::DataPacket.new("success")
    end

    def handle_invoke(params)
        puts "handle_invoke"
        puts params
        id = params["id"]
        args = params["args"].to_s
        puts "EXEC #{id} #{args}\r"
        @serial_connection.puts "EXEC #{id} #{args}\r"
        reply = nil
        while reply.nil? do
            resp = @serial_connection.gets
            unless resp.nil?
                begin
                    resp.strip!
                rescue Exception => e
                    # After programming (on nrf91 at least) there's sometimes a duff
                    # byte or two at the start of the buffer
                    puts "strip! failed #{e}"
                    new_resp = ""
                    resp.bytes do |c|
                        puts "%3d 0x%02X" % [ c, c ]
                        if c < 128 and c > 8
                            # It's a "normal" ASCII byte, let it through the filter
                            new_resp = new_resp + c.chr
                        end
                    end
                    puts "Filtered version is >>#{new_resp}<<"
                    resp = new_resp
                end
                # See if it's a response to the EXEC (i.e. does it start with [RESULT])
                parsed_resp = /cucumber: (\-?\d+)/.match(resp)
                if parsed_resp
                    reply = parsed_resp[1]
                else
                    # It's not a reply, just some debug logging, print that out
                    puts "LOG: #{resp}"
                end
            end
        end

        if reply == "0"
            Cucumber::Wire::DataPacket.new("success")
        else
            Cucumber::Wire::DataPacket.new("fail", params = {"message": "Step failed with #{resp}"})
        end
    end

    private

    # Props to Rails
    def underscore(camel_cased_word)
        camel_cased_word.to_s.gsub(/::/, '/').
        gsub(/([A-Z]+)([A-Z][a-z])/,'\1_\2').
        gsub(/([a-z\d])([A-Z])/,'\1_\2').
        tr("-", "_").
        downcase
    end
end

# Check we've got the right arguments
if ARGV.length != 2
    puts "Wrong number of arguments"
    puts
    puts "Usage: server.rb <serial port> <listening port>"
    puts
    exit(2)
end

serial_port = ARGV[0]
server_port = ARGV[1].to_i

# Load in the steps
steps_data = File.read('steps.json') or die "Can't find steps.json file"
steps = JSON.parse(steps_data)

# Open listening socket
server = TCPServer.new server_port

request_handler = RequestHandler.new(serial_port, steps)

# Accept new connections
loop do
    puts
    puts "Waiting for connections..."
    client = server.accept
    wc = WireConnectionWithSocket.new(client)

    loop do
        begin
            rmsg = wc.recv_packet(request_handler)
        rescue Cucumber::Wire::Exception => e
            if e.message.include?("closed")
                # This is fine, we've just reached the end
                # of the tests
                break
            else
                raise e
            end
        end
    end
end

