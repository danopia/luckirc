# irc.rb: Ruby IRC bot library
# Copyright (c) 2009 Nick Markwell (duckinator/RockerMONO on irc.freenode.net)

require 'socket'
require 'eventmachine'

require File.join(File.dirname(__FILE__), 'event_context')

#$SAFE=1

class IRC < EventMachine::Connection
  attr_accessor :ip, :port, :nick, :channels, :admins, :ident, :realname, :test
  
  def self.create_test_instance
    irc = allocate
    irc.test = true
    
    irc.port = 6667
    irc.ip = '127.0.0.1'
    
    irc.nick = 'test'
    irc.channels = '#test'
    irc.admins = 'test::bot'
    irc.ident = 'test'
    irc.realname = 'A fake instance, ready for testing'
    
    irc
  end
  def test_packet packet
    @sent = []
    receive_data packet
    @sent = @sent.first if @sent.size < 2
    sent, @sent = @sent, nil
    sent
  end
  
  def self.connect server, port, *args
    EventMachine::connect server, port, self, *args
  end
  def self.start_loop *args
    EventMachine::run { self.connect *args }
  end

  @@commands = nil
  @@handlers = nil
  def self.command name, help=nil, adminonly=false, &blck
    reset_commands unless @@commands
    @@commands[name.downcase] = {:name => name, :block => blck, :help => help, :adminonly => adminonly}
  end
  def self.reset_commands
    @@commands = {}
    
    command 'help', 'Helps you out with the commands this bot has.' do |e|
      cmd = @@commands[e.params.first]
      
      if e.params.none?
        e.respond "My commands: #{@@commands.keys.join ', '}. Pass them to this help command for more information on an individual command."
      elsif cmd
        e.respond "#{cmd[:name]}: #{cmd[:help]}" + (cmd[:adminonly] ? '. Admin only.' : '')
      else
        e.respond "I can't find the #{e.params.first} command."
      end
    end
    
    command 'test', 'Tests the bot by providing a simple request.' do |e|
      e.respond "It works!"
    end
  end
  def self.commands
    @@commands
  end
  
  def self.on event, &blck
    reset_hooks unless @@handlers
    
    @@handlers[event.to_sym] ||= []
    @@handlers[event.to_sym] << blck
  end
  def self.reset_hooks
    @@handlers = {}
    
    # Only three come stock:
    # :ping (to pong)
    on :ping do |e|
      e.conn.send 'pong', *e.params
    end
    
    # :message (to emit :command),
    on :message do |e|
      
      # Comchars
      if e.param.index($config['cc']) == 0 && e.param.size > $config['cc'].size
        params = e.param[$config['cc'].size..-1].split ' '

        e.conn.handle :command, e.origin, e.target, *params
        
      else			
        # Addressing
        params = e.param.split ' '
        params.unshift e.conn.nick if e.pm?
        
        next if params.size < 2 || params.first.index(e.conn.nick) != 0
        next if params.first.size > e.conn.nick.size + 1
        
        params.shift
        e.conn.handle :command, e.origin, e.target, *params
      end
    end
    
    # and :command to hook into the command system (this is separate to support
    # third-party :command callers such as CTCP)
    on :command do |e|
      command = @@commands[e.params.first.downcase]
      
      if command.nil?
        # Silenced to be nice with Slack's bot, Isabella
        #e.respond "\003\003No such command: #{e.params.first}"
      elsif command[:adminonly] && !e.conn.admin?
        e.respond "You much be a bot administrator to run #{e.params.first}."
      else
        # don't like how I modify e. only matters for multiple hooks though.
        e.event = e.params.shift.to_sym
        command[:block].call e
      end
    end
  end
  
  def self.unhook event
    @@handlers.delete event.to_sym
  end
  
  def initialize(nick, channels=nil, admins=[], ident=nil, realname=nil, password=nil)
    super()
    
    begin
      @port, @ip = Socket.unpack_sockaddr_in get_peername
      puts "Connected to IRC at #{@ip}:#{@port}"
    rescue TypeError
      puts "Unable to determine endpoint (connection refused?)"
    end
    
    @nick = nick
    @channels = channels
    @admins = admins
    @ident = ident || @nick
    @realname = realname || "#{@nick} - powered by danopia's IRC library"
    @password = password

    @buffer = ''
    @@instance = self
    
    start_irc
  end
  
  def unbind
    puts "Disconnected from IRC"
    EventMachine.stop_event_loop
  end
  
  def admin? who
    @admins.include?(who.is_a?(Hash) ? who[:host] : who)
  end
  
  def send *params
    if params.last == true
      params.pop
      params.push ":#{params.pop}"
    end
    
    params[0].upcase!
    params[1] = params[1][:nick] if params.size > 0 && params[1].is_a?(Hash)
    
    send_data "#{params.join ' '}\n"
  end
  def send_data data
    @sent ||= [] if @test
    
    if @sent
      @sent << data
    else
      super
    end
  end
  
  def start_irc
    set_comm_inactivity_timeout 120 # 2 minutes
    
    send 'PASS', @password if @password
    self.nick = @nick # send packet
    send 'USER', @ident, '0', '0', @realname, true
    join @channels if @channels
    handle :connect
  end
  
  def nick=(nick)
    @nick = nick
    send 'NICK', @nick
  end
  
  def message target, message
    puts "--> [MSG/#{target}] #{message}"
    send 'PRIVMSG', target, message, true
  end
  def notice target, message
    puts "--> [NOT/#{target}] #{message}"
    send 'NOTICE', target, message, true
  end
  
  alias privmsg message
  
  def ctcp target, command, args=''
    message target, build_ctcp(command, args)
  end
  def ctcp_reply target, command, args=''
    notice target, build_ctcp(command, args)
  end
  
  def action target, message
    ctcp target, 'action', message
  end
  
  def join channel
    puts "--> Joining #{channel}"
    send 'JOIN', channel
  end
  def part channel, message='Leaving'
    puts "--> Parting #{channel}"
    send 'PART', channel, message, true
  end
  
  def quit message='Leaving'
    puts "--> Quiting: \"#{message}\""
    send 'QUIT', message, true
  end
  
  def handle event, origin=nil, target=nil, *params
    e = EventContext.new self, event, origin, target, params

    puts "Handling #{event} from #{origin[:nick]} to #{target} with params #{params.join ' '}" if origin
    
    return unless @@handlers[e.event]
    
    @@handlers[event].each do |block|
      begin
        block.call e
      rescue => ex
        if event == :error
          begin
            e.respond "Double-fault occurred! #{e.params.first.class} #{e.params.first.message} followed by #{ex.class} #{ex.message}"
          rescue => ex2
            puts "ZOMG! Triple-fault! You might want to check something."
            puts
            puts 'First:', e.params.first.class, e.params.first.message, e.params.first.backtrace
            puts
            puts 'Second:', ex2.class, ex2.message, ex2.backtrace
            exit
          end
        else
          handle :error, origin, target, ex, *params
        end
      end
    end
  end
  
  def receive_data packet
    packet.strip!
    
    parts = packet.split ' :', 2
    args = parts[0].split ' '
    args << parts[1] if parts.size > 1
    
    origin = nil
    
    if args.first[0,1] == ':'
      parts = (args.shift)[1..-1].split('!', 2)
      if parts.size > 1
        parts[1], parts[2] = parts[1].split('@', 2)
        origin = {:ident => parts[1], :host => parts[2]}
      else
        origin = {:server => true}
      end
      
      origin[:nick] = parts[0]
    end
    
    command = args.shift
    
    case command.downcase
    when 'ping'
      handle :ping, origin, *args
      
    when 'privmsg'
      handle_message :message, origin, args
    when 'notice'
      handle_message :notice, origin, args
      
    when 'join'
      handle :join, origin, *args
    when 'part'
      handle :part, origin, *args
    when 'quit'
      handle :quit, origin, nil, *args
      
    else
      handle :unhandled, origin, command, nil, *args
    end
  end
  
  protected
  
  def handle_message type, origin, args
    if ctcp? args[1]
      handle_ctcp type, origin, *args
    else
      handle type, origin, *args
    end
  end
  
  def ctcp? string
    string[0,1] == "\001" && string[-1,1] == "\001"
  end
  
  def handle_ctcp type, origin, target, message
    message = message[1..-2]
    args = message.split ' '
    command = args.shift.upcase
    type = (type == :message) ? :ctcp : :ctcp_response
    
    handle type, origin, target, command, args
  end
  
  def build_ctcp command, args=''
    command.upcase!
    args = args.join ' ' if args.is_a? Array
    command << " #{args}" if args.any?
    "\001#{command}\001"
  end
end
