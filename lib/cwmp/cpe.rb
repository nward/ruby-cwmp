require 'httpclient'
require 'socket'
require 'xmpp4r/client'
require 'nokogiri'
include Jabber

module Cwmp

    class Cpe
        attr_accessor :serial, :oui, :software_version, :manufacturer, :acs_url, :state

        def initialize (acs_url, periodic, h = {})
            @acs_url = acs_url
            @serial = h[:serial] || "23434ds"
            @oui = h[:oui] || "006754"
            @software_version = h[:software_version] || Cwmp::VERSION
            @manufacturer = h[:manufacturer] || "ruby-cwmp"
            @state = 'off'
            @periodic = Thread.new { periodic periodic } if periodic > 0
            @conn_req = Thread.new { connection_request }
            @xmpp_req = Thread.new { xmpp_connection_request }
            @factory = true
        end

        def poweron
            @state = 'on'
            if @factory
                do_connection '0 BOOTSTRAP'
            else
                do_connection '1 BOOT'
            end
            @factory = false
        end

        def poweroff
            @state = 'off'
        end

        def reboot
            @state = 'off'
            sleep 2
            @state = 'on'
            do_connection '1 BOOT'
        end

        def reset
            poweroff
            @factory = true
            poweron
        end

        def loop
            @xmpp_req.join
            @conn_req.join
        end

        private

        def periodic time
            puts "setting periodic inform every #{time} seconds"
            while true
                sleep time
                do_connection '2 PERIODIC'
            end
        end

        def connection_request
            server = TCPServer.open(9600)
            while true
                client = server.accept

                response = "<html>...</html>"
                headers = ["HTTP/1.0 200 OK",
                           "Content-Type: text/html",
                           "Content-Length: #{response.length}"].join("\r\n")

                client.puts headers
                client.puts "\r\n\r\n"
                client.puts response

                client.close

                do_connection '6 CONNECTION REQUEST'
            end
        end

        def xmpp_connection_request
            puts "start xmpp connection"
            myJID = JID.new('cpe@mosesacs.org/casatua')
            myPassword = 'pass'
            cl = Client.new(myJID)
            cl.connect
            cl.auth(myPassword)
            cl.send(Presence.new)
            puts "Connected ! send messages to #{myJID.strip.to_s}."

            mainthread = Thread.current
            cl.add_iq_callback do |m|
                if m.type == :error
                    puts "error"
                elsif m.type == :get
                    puts "send xmpp connection request result"

                    puts "#{xmpp_connection_request_response_iq(m.from)}"
                    cl.send(xmpp_connection_request_response_iq(m.from))

                    puts "send Inform with event CONNECTION REQUEST"
                    do_connection '6 CONNECTION REQUEST'
                end

            end
            Thread.stop
            cl.close

        end

        def xmpp_connection_request_response_iq from
            iq = Iq.new(:result)
            iq.from = 'cpe1@mosesacs.org'
            iq.to = from
            iq.id = 'cr001'
            iq.add_namespace('urn:broadband-forum-org:cwmp:xmppConnReq-1-0')
            return iq
        end

        def xmpp_connection_request_iq
            iq = Iq.new(:get)
            iq.from = 'cpe1@mosesacs.org'
            iq.to = 'acs@mosesacs.org'
            iq.id = 'cr001'
            iq.add_namespace('urn:broadband-forum-org:cwmp:xmppConnReq-1-0')
            cr = iq.add REXML::Element.new('connectionRequest')
            cr.add_namespace('urn:broadband-forum-org:cwmp:xmppConnReq-1-0')
            cr.add(REXML::Element.new('username').add_text('username'))
            cr.add(REXML::Element.new('password').add_text('password'))
            iq.add(cr)
            return iq
        end

        def do_connection(event)
            begin
                c = HTTPClient.new

                puts "sending Inform with event #{event}"
                resp = c.post @acs_url, Cwmp::Message::inform(@manufacturer, @oui, @serial, event, @software_version).xml, {'User-Agent' => "ruby-cwmp #{Cwmp::VERSION}", "Content-Type" => 'text/xml; charset="utf-8"'}
                doc = Nokogiri::XML(resp.body)
                resp.body =~ /(\w+):Envelope/
                soap_ns = $1
                message_type = doc.css("#{soap_ns}|Body").children.map(&:name)[1]
                puts "got #{message_type} message"
                resp = c.post @acs_url, "", {'User-Agent' => "ruby-cwmp #{Cwmp::VERSION}", "Content-Type" => 'text/xml; charset="utf-8"'}
                while resp.status != 204
                    doc = Nokogiri::XML(resp.body)
                    message_type = doc.css("#{soap_ns}|Body").children.map(&:name)[1]
                    puts "got #{message_type}"
                    case message_type
                        when "cwmp:GetParameterValues"
                            resp = c.post @acs_url, (Cwmp::Message::get_parameter_values_response).xml, {'User-Agent' => "ruby-cwmp #{Cwmp::VERSION}", "Content-Type" => 'text/xml; charset="utf-8"'}
                        when "cwmp:GetParameterNames"
                            resp = c.post @acs_url, (Cwmp::Message::get_parameter_names_response).xml, {'User-Agent' => "ruby-cwmp #{Cwmp::VERSION}", "Content-Type" => 'text/xml; charset="utf-8"'}
                        when "cwmp:SetParameterValues"
                            resp = c.post @acs_url, (Cwmp::Message::set_parameter_values_response).xml, {'User-Agent' => "ruby-cwmp #{Cwmp::VERSION}", "Content-Type" => 'text/xml; charset="utf-8"'}
                        when "cmwp:ChangeDUState"
                            resp = c.post @acs_url, (Cwmp::Message::change_du_state_response).xml, {'User-Agent' => "ruby-cwmp #{Cwmp::VERSION}", "Content-Type" => 'text/xml; charset="utf-8"'}
                    end
                end
                puts "got a #{resp.status}, closing"
                c.reset @acs_url
            rescue Errno::ECONNREFUSED
                puts "can't connect to #{@acs_url}"
                exit(1)
            end
        end

    end

end