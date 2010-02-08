
class EventContext
	attr_reader :conn, :event, :origin, :target, :reply_to, :params
  attr_writer :event, :params
	
	def initialize conn, event, origin, target, params
		@conn = conn
		@event = event
		@origin = origin
		@target = target
		@params = params
		
		@reply_to = pm? ? origin : target
	end
	
	def param
		@params.join ' '
	end
	
	def pm?
		@conn.nick == @target
	end
	def channel?
		@conn.nick != @target
	end
	
	def ctcp?
		@event == :ctcp || @event == :ctcp_reply
	end
	
	def admin?
		@conn.admin? origin
	end
	
	def message message
		@conn.message @reply_to, message
	end
	def notice message
		@conn.notice @reply_to, message
	end
	def action message
		@conn.action @reply_to, message
	end
	
	def respond message
		if ctcp?
			raise StandardError, 'cannot respond to a CTCP response' if @event == :notice
			@conn.ctcp_reply @origin, @params.first, message
			return
		end
		
		message = pm? ? message : "#{origin[:nick]}: #{message}"
		
		if @event == :notice
			self.notice message
		else
			self.message message
		end
	end
	
end # event_context class
