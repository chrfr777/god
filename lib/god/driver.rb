module God
  class TimedEvent
    include Comparable

    attr_accessor :at
    
    # Instantiate a new TimedEvent that will be triggered after the specified delay
    #   +delay+ is the number of seconds from now at which to trigger
    #
    # Returns TimedEvent
    def initialize(delay = 0)
      self.at = Time.now + delay
    end

    def due?
      Time.now >= self.at
    end

    def <=>(other)
      self.at <=> other.at
    end
  end # DriverEvent

  class DriverEvent < TimedEvent
    attr_accessor :condition, :task
    
    def initialize(delay, task, condition)
      super delay
      self.task = task
      self.condition = condition
    end
    
    def handle_event
      @task.handle_poll(@condition)
    end
  end # DriverEvent

  class DriverOperation < TimedEvent
    attr_accessor :task, :name, :args

    def initialize(task, name, args)
      super(0)
      self.task = task
      self.name = name
      self.args = args
    end
    
    # Handle the next queued operation that was issued asynchronously
    #
    # Returns nothing
    def handle_event
      @task.send(@name, *@args)
    end
  end

  class DriverEventQueue
    def initialize
      @shutdown = false
      @events = []
      @mutex = Mutex.new
      @resource = ConditionVariable.new
      @events.taint
      self.taint
    end

    #
    # Wake any sleeping threads after setting the sentinel
    #
    def shutdown
      @shutdown = true
      @mutex.synchronize do
        @resource.broadcast
      end
    end

    #
    # Sleep until the queue has something due
    #
    def pop
      @mutex.synchronize do
        if @events.empty?
          raise ThreadError, "queue empty" if @shutdown
          @resource.wait(@mutex)
        else !@events.first.due?
          delay = @events.first.at - Time.now
          @resource.wait(@mutex, delay) if delay > 0
        end

        @events.shift
      end
    end

    alias shift pop
    alias deq pop

    #
    # Add an event to the queue, wake any waiters if what we added needs to
    # happen sooner than the next pending event
    #
    def push(event)
      @mutex.synchronize do
        @events << event
        @events.sort!

        @resource.signal if @events.first == event
      end
    end

    alias << push
    alias enq push

    def empty?
      @events.empty?
    end

    def clear
      @events.clear
    end

    def length
      @events.length
    end

    alias size length
  end


  class Driver
    attr_reader :thread

    # Instantiate a new Driver and start the scheduler loop to handle events
    #   +task+ is the Task this Driver belongs to
    #
    # Returns Driver
    def initialize(task)
      @task = task
      @events = God::DriverEventQueue.new
      
      @thread = Thread.new do
        loop do
          begin
            @events.pop.handle_event
          rescue ThreadError => e
            # queue is empty
            break
          rescue Object => e
            message = format("Unhandled exception in driver loop - (%s): %s\n%s",
                             e.class, e.message, e.backtrace.join("\n"))
            applog(nil, :fatal, message)
          end
        end
      end
    end
    
    # Clear all events for this Driver
    # 
    # Returns nothing
    def clear_events
      @events.clear
    end

    # Shutdown the DriverEventQueue threads
    #
    # Returns nothing
    def shutdown
      @events.shutdown
    end
    
    # Queue an asynchronous message
    #   +name+ is the Symbol name of the operation
    #   +args+ is an optional Array of arguments
    #
    # Returns nothing
    def message(name, args = [])
      @events.push(DriverOperation.new(@task, name, args))
    end
    
    # Create and schedule a new DriverEvent
    #   +condition+ is the Condition
    #   +delay+ is the number of seconds to delay (default: interval defined in condition)
    #
    # Returns nothing
    def schedule(condition, delay = condition.interval)
      applog(nil, :debug, "driver schedule #{condition} in #{delay} seconds")
      
      @events.push(DriverEvent.new(delay, @task, condition))
    end
  end # Driver
  
end # God
