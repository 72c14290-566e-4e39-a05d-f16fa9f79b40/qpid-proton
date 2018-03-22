# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.


require 'test_tools'
require 'minitest/unit'
require 'socket'

# MessagingHandler that raises in on_error to catch unexpected errors
class ExceptionMessagingHandler
  def on_error(e) raise e; end
end

class ContainerTest < MiniTest::Test
  include Qpid::Proton

  def test_simple()
    send_handler = Class.new(ExceptionMessagingHandler) do
      attr_reader :accepted, :sent

      def initialize() @sent, @accepted = nil; end

      def on_sendable(sender)
        unless @sent
          m = Message.new("hello")
          m[:foo] = :bar
          sender.send m
        end
        @sent = true
      end

      def on_tracker_accept(tracker)
        @accepted = true
        tracker.connection.close
      end
    end.new

    receive_handler = Class.new(ExceptionMessagingHandler) do
      attr_reader :message, :link
      def on_receiver_open(link)
        @link = link
        @link.open
        @link.flow(1)
      end

      def on_message(delivery, message)
        @message = message;
        delivery.update Disposition::ACCEPTED
        delivery.settle
      end
    end.new

    c = ServerContainer.new(__method__, {:handler => receive_handler})
    c.connect(c.url, {:handler => send_handler}).open_sender({:name => "testlink"})
    c.run

    assert send_handler.accepted
    assert_equal "testlink", receive_handler.link.name
    assert_equal "hello", receive_handler.message.body
    assert_equal :bar, receive_handler.message[:foo]
    assert_equal "test_simple", receive_handler.link.connection.container_id
  end

  class CloseOnOpenHandler < TestHandler
    def on_connection_open(c) super; c.close; end
  end

  def test_auto_stop_one
    # A listener and a connection
    start_stop_handler = Class.new do
      def on_container_start(c) @start = c; end
      def on_container_stop(c) @stop = c; end
      attr_reader :start, :stop
    end.new
    c = Container.new(start_stop_handler, __method__)
    threads = 3.times.collect { Thread.new { c.run } }
    sleep(0.01) while c.running < 3
    assert_equal c, start_stop_handler.start
    l = c.listen_io(TCPServer.new(0), ListenOnceHandler.new({ :handler => CloseOnOpenHandler.new}))
    c.connect("amqp://:#{l.to_io.addr[1]}", { :handler => CloseOnOpenHandler.new} )
    threads.each { |t| assert t.join(1) }
    assert_equal c, start_stop_handler.stop
    assert_raises(Container::StoppedError) { c.run }
  end

  def test_auto_stop_two
    # Connect between different containers
    c1, c2 = Container.new("#{__method__}-1"), Container.new("#{__method__}-2")
    threads = [ Thread.new {c1.run }, Thread.new {c2.run } ]
    l = c2.listen_io(TCPServer.new(0), ListenOnceHandler.new({ :handler => CloseOnOpenHandler.new}))
    c1.connect(l.url, { :handler => CloseOnOpenHandler.new} )
    assert threads.each { |t| t.join(1) }
    assert_raises(Container::StoppedError) { c1.run }
    assert_raises(Container::StoppedError) { c2.connect("") }
  end

  def test_auto_stop_listener_only
    c = Container.new(__method__)
    # Listener only, external close
    t = Thread.new { c.run }
    l = c.listen_io(TCPServer.new(0))
    l.close
    assert t.join(1)
  end

  def test_stop_empty
    c = Container.new(__method__)
    threads = 3.times.collect { Thread.new { c.run } }
    sleep(0.01) while c.running < 3
    assert_nil threads[0].join(0.001) # Not stopped
    c.stop
    assert c.stopped
    assert_raises(Container::StoppedError) { c.connect("") }
    assert_raises(Container::StoppedError) { c.run }
    threads.each { |t| assert t.join(1) }
  end

  def test_stop
    c = Container.new(__method__)
    c.auto_stop = false

    l = c.listen_io(TCPServer.new(0))
    threads = 3.times.collect { Thread.new { c.run } }
    sleep(0.01) while c.running < 3
    l.close
    assert_nil threads[0].join(0.001) # Not stopped, no auto_stop

    l = c.listen_io(TCPServer.new(0)) # New listener
    conn = c.connect("amqp://:#{l.to_io.addr[1]}")
    c.stop
    assert c.stopped
    threads.each { |t| assert t.join(1) }

    assert_raises(Container::StoppedError) { c.run }
    assert_equal 0, c.running
    assert_nil l.condition
    assert_nil conn.condition
  end

  def test_bad_host
    cont = Container.new(__method__)
    assert_raises (SocketError) { cont.listen("badlisten.example.com:999") }
    assert_raises (SocketError) { cont.connect("badconnect.example.com:999") }
  end

  # Verify that connection options are sent to the peer
  def test_connection_options
    # Note: user, password and sasl_xxx options are tested by ContainerSASLTest below
    server_handler = Class.new(ExceptionMessagingHandler) do
      def on_connection_open(c)
        @connection = c
        c.open({
          :virtual_host => "server.to.client",
          :properties => { :server => :client },
          :offered_capabilities => [ :s1 ],
          :desired_capabilities => [ :s2 ],
          :container_id => "box",
        })
        c.close
      end
      attr_reader :connection
    end.new
    # Transport options set by listener, by Connection#open it is too late
    cont = ServerContainer.new(__method__, {
      :handler => server_handler,
      :idle_timeout => 88,
      :max_sessions =>1000,
      :max_frame_size => 8888,
    })
    client = cont.connect(cont.url,
      {:virtual_host => "client.to.server",
        :properties => { :foo => :bar, "str" => "str" },
        :offered_capabilities => [:c1 ],
        :desired_capabilities => ["c2" ],
        :idle_timeout => 42,
        :max_sessions =>100,
        :max_frame_size => 4096,
        :container_id => "bowl"
      })
    cont.run

    c = server_handler.connection
    assert_equal "client.to.server", c.virtual_host
    assert_equal({ :foo => :bar, :str => "str" }, c.properties)
    assert_equal([:c1], c.offered_capabilities)
    assert_equal([:c2], c.desired_capabilities)
    assert_equal 21, c.idle_timeout # Proton divides by 2
    assert_equal 100, c.max_sessions
    assert_equal 4096, c.max_frame_size
    assert_equal "bowl", c.container_id

    c = client
    assert_equal "server.to.client", c.virtual_host
    assert_equal({ :server => :client }, c.properties)
    assert_equal([:s1], c.offered_capabilities)
    assert_equal([:s2], c.desired_capabilities)
    assert_equal "box", c.container_id
    assert_equal 8888, c.max_frame_size
    assert_equal 44, c.idle_timeout # Proton divides by 2
    assert_equal 100, c.max_sessions
  end

  def test_link_options
    server_handler = Class.new(ExceptionMessagingHandler) do
      def initialize() @links = []; end
      attr_reader :links
      def on_sender_open(l) @links << l; end
      def on_receiver_open(l) @links << l; end
    end.new

    client_handler = Class.new(ExceptionMessagingHandler) do
      def on_connection_open(c)
        @links = [];
        @links << c.open_sender("s1")
        @links << c.open_sender({:name => "s2-n", :target => "s2-t", :source => "s2-s"})
        @links << c.open_receiver("r1")
        @links << c.open_receiver({:name => "r2-n", :target => "r2-t", :source => "r2-s"})
        c.close
      end
      attr_reader :links
    end.new

    cont = ServerContainer.new(__method__, {:handler => server_handler }, 1)
    cont.connect(cont.url, :handler => client_handler)
    cont.run

    expect = ["test_link_options/1", "s2-n", "test_link_options/2", "r2-n"]
    assert_equal expect, server_handler.links.map(&:name)
    assert_equal expect, client_handler.links.map(&:name)

    expect = [[nil,"s1"], ["s2-s","s2-t"], ["r1",nil], ["r2-s","r2-t"]]
    assert_equal expect, server_handler.links.map { |l| [l.remote_source.address, l.remote_target.address] }
    assert_equal expect, client_handler.links.map { |l| [l.source.address, l.target.address] }
  end

  # Test for time out on connecting to an unresponsive server
  def test_idle_timeout_server_no_open
    s = TCPServer.new(0)
    cont = Container.new(__method__)
    cont.connect(":#{s.addr[1]}", {:idle_timeout => 0.1, :handler => ExceptionMessagingHandler.new })
    ex = assert_raises(Qpid::Proton::Condition) { cont.run }
    assert_match(/resource-limit-exceeded/, ex.to_s)
  ensure
    s.close if s
  end

  # Test for time out on unresponsive client
  def test_idle_timeout_client
    server = ServerContainerThread.new("#{__method__}.server", {:idle_timeout => 0.1})
    client_handler = Class.new(ExceptionMessagingHandler) do
      def initialize() @ready, @block = Queue.new, Queue.new; end
      attr_reader :ready, :block
      def on_connection_open(c)
        @ready.push nil        # Tell the main thread we are now open
        @block.pop             # Block the client so the server will time it out
      end
    end.new

    client = Container.new(nil, "#{__method__}.client")
    client.connect(server.url, {:handler => client_handler})
    client_thread = Thread.new { client.run }
    client_handler.ready.pop    # Wait till the client has connected
    server.join                 # Exits when the connection closes from idle-timeout
    client_handler.block.push nil   # Unblock the client
    ex = assert_raises(Qpid::Proton::Condition) { client_thread.join }
    assert_match(/resource-limit-exceeded/, ex.to_s)
  end

  # Make sure we stop and clean up if an aborted connection causes a handler to raise.
  # https://issues.apache.org/jira/browse/PROTON-1791
  def test_handler_raise
    cont = ServerContainer.new(__method__, {}, 0) # Don't auto-close the listener
    client_handler = Class.new(MessagingHandler) do
      # TestException is < Exception so not handled by default rescue clause
      def on_connection_open(c) raise TestException.new("Bad Dog"); end
    end.new
    threads = 3.times.collect { Thread.new { cont.run } }
    sleep 0.01 while cont.running < 3 # Wait for all threads to be running
    sockets = 2.times.collect { TCPSocket.new("", cont.port) }
    cont.connect_io(sockets[1]) # No exception
    cont.connect_io(sockets[0], {:handler => client_handler}) # Should stop container

    threads.each { |t| assert_equal("Bad Dog", assert_raises(TestException) {t.join}.message) }
    sockets.each { |s| assert s.closed? }
    assert cont.listener.to_io.closed?
    assert_raises(Container::StoppedError) { cont.run }
    assert_raises(Container::StoppedError) { cont.listen "" }
  end

  # Make sure Container::Scheduler puts tasks in proper order.
  def test_scheduler
    a = []
    s = Schedule.new

    assert_equal true,  s.add(Time.at 3) { a << 3 }
    assert_equal false, s.process(Time.at 2)      # Should not run
    assert_equal [], a
    assert_equal true, s.process(Time.at 3)      # Should run
    assert_equal [3], a

    a = []
    assert_equal true, s.add(Time.at 3) { a << 3 }
    assert_equal false, s.add(Time.at 5) { a << 5 }
    assert_equal false, s.add(Time.at 1) { a << 1 }
    assert_equal false, s.add(Time.at 4) { a << 4 }
    assert_equal false, s.add(Time.at 4) { a << 4.1 }
    assert_equal false, s.add(Time.at 4) { a << 4.2 }
    assert_equal false, s.process(Time.at 4)
    assert_equal [1, 3, 4, 4.1, 4.2], a
    a = []
    assert_equal true, s.process(Time.at 5)
    assert_equal [5], a
  end

  def test_container_schedule
    c = Container.new __method__
    delays = [0.1, 0.03, 0.02, 0.04]
    a = []
    delays.each { |d| c.schedule(d) { a << [d, Time.now] } }
    start = Time.now
    c.run
    delays.sort.each do |d|
      x = a.shift
      assert_equal d, x[0]
      assert_in_delta  start + d, x[1], 0.01, "#{d}"
    end
  end
end
