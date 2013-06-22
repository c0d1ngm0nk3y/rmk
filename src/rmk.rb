#!/usr/bin/env ruby
require 'rubygems'
require 'digest/md5'
require 'eventmachine'
require 'fiber'

class MethodCache
  def initialize(delegate)
    @cache = Hash.new
    @delegate = delegate
  end
  def method_missing(m, *args, &block)
    key = m.to_s + args.to_s
    begin
      @cache[key] ||= @delegate.send(m,*args,&block)
    rescue Exception => exc
      #exc.backtrace.each do | c |
      #  raise "#{c} : #{exc.message} #{exc.backtrace.join("\n")}" if c =~ /build.rmk/
      #end
      raise "#{@delegate.to_s}:#{m.to_s} : #{exc.message} #{exc.backtrace.join("\n")}"
    end
  end
end


class File
  def self.relative_path_from(src,base)
    s = src.split("/")
    b = base.split("/")
    j = 0
    return src if s[1] != b[1]
    return "./" if s == b
    for i in 0...s.length
      if s[i] != b[i]
        j = i
        break
      end
    end
    return "." if j == 0 && s.length == b.length
    (Array.new(b.length-j,"..") + s[j..-1]).join("/")
  end
end

module PipeReader
  def initialize(fiber)
    @fiber = fiber
  end
  def receive_data(data)
    STDOUT.write(data)
  end
  def unbind
    @fiber.resume get_status.exitstatus
  end
end

class BuildFuture
  def initialize(&block)
    current = Fiber.current
		Fiber.new do 
			begin
				result = block.call()
				EventMachine.next_tick do
					current.resume result if current.alive?
				end
			rescue Exception => exc
				EventMachine.next_tick do
					current.resume exc if current.alive?
				end
			end
		end.resume
  end
  def value()
		result = Fiber.yield
		raise result if result.is_a?(Exception)
		result
  end
end

class ImmediateFuture
	attr_reader :value
  def initialize(value)
    @value = value
  end
end

module BuildTools
  def system(cmd)
    message = cmd.gsub(/(\/[^\s:]*\/)/) { File.relative_path_from($1,Dir.getwd) + "/" }
    puts(message)
    EventMachine.popen(cmd, PipeReader,Fiber.current)
    raise "Error running xxx" unless Fiber.yield == 0
  end
  def parallel(files,&block)
    futures = []
    files.each do  | file |
      futures << BuildFuture.new do 
				block.call(file)
			end
    end
    futures.each { | f | f.value() }
  end
end

class BuildFile

  BUILD_DIR = "build"
  
  def initialize(build_file_cache,file)
    @build_file_cache = build_file_cache
    @file = file
    @dir = File.dirname(file)
  end
  
  def self.file=(value)
    @dir = File.dirname(value)
  end
  
  def project(file)
    @build_file_cache.load(file,@dir)
  end
  
  def self.plugin(name)
    Kernel.require File.join(File.expand_path(File.dirname(File.dirname(__FILE__))),"plugins",name + ".rb")
    include const_get(name.capitalize)
  end
  
  def self.load(name)
    file = File.join(@dir,name)
    content = File.read(file)
    self.module_eval(content,file,1)
  end
  
  def build_cache(depends,&block)
    md5 = Digest::MD5.new
    c = caller
    md5.update(c[0])
    md5.update(c[1])
    depends.each { | d | md5.update(d.to_s) }
    file = File.join(@dir,BUILD_DIR,"cache/#{md5.hexdigest}")
    begin
      depends += File.open(file +".dep","rb") { | f | Marshal.load(f) } 
    rescue Errno::ENOENT
    end
    rebuild = true
    if File.readable?(file)
      rebuild = false
      mtime = File.mtime(file)
      depends.each do | d |
        dmtime = d.is_a?(String) ? File.mtime(d) : d.mtime
        if dmtime > mtime
          rebuild = true 
          break
        end
      end
    end
    if rebuild
    	result = BuildFuture.new do
      	hidden = []
      	res = block.call(hidden) 
      	FileUtils.mkdir_p(File.dirname(file))
      	File.open(file,"wb") { | f | Marshal.dump(res,f) }
      	File.open(file +".dep","wb") { | f | Marshal.dump(hidden,f) } unless hidden.empty?
      	res
      end
    else
      result = ImmediateFuture.new(File.open(file,"rb") { | f | Marshal.load(f) })
    end 
    result
  end
  
  def glob(pattern)
    Dir.glob(File.join(@dir,pattern))
  end
  
  def dir()
    @dir
  end
  
  def build_dir()
    File.join(@dir,BUILD_DIR)
  end
  
  def file(name)
    return File.join(@dir,name) if name.is_a?(String)
    name.to_a.map{ | x | File.join(@dir,x) }
  end
  
  def to_s()
    @file
  end
end

class BuildFileCache
  def initialize()
    @cache = Hash.new
  end
  def load(file,dir = ".")
    file = File.expand_path(File.join(dir,file))
    file = File.join(file,"build.rmk") if File.directory?(file)
    @cache[file] ||= load_inner(file)
  end
  def load_inner(file)
    build_file = Class.new(BuildFile)
    content = File.read(file)
    build_file.file = file
    build_file.module_eval(content,file,1)
    MethodCache.new(build_file.new(self,file))
  end
end

result = 0
EventMachine.run do
  Fiber.new do 
    build_file_cache = BuildFileCache.new()
    build_file = build_file_cache.load("build.rmk")
    task = ARGV[0] || "all"
    begin
      build_file.send(task.intern)
      puts "Build OK"
    rescue Exception => exc
      STDERR.puts exc.message
      puts "Build Failed"
      result = 1
    end
    EventMachine.stop
  end.resume
end
exit(result)
