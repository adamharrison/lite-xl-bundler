#!/usr/bin/env ruby

require 'socket'
require 'cgi'
require 'json'
require 'fileutils'
require 'date'
require 'timeout'

def log(request_number, type, message)
  printf("[%8s][%s][%08d]: %s\n", type, DateTime.now.iso8601, request_number, message)
end

def system_log(request_number, cmd, exp)
  log(request_number, "SYSTEM", cmd)
  results = `#{cmd}`
  raise exp if $?.exitstatus != 0
  return results
end

@temporary_directory = "tmp"

def handle_request(request_number, method, path, query, headers) 
  version = "2.1-simplified"
  platform = nil
  plugins = []
  query.split("&").each { |x| 
    name, value = x.split("=")
    value = CGI.unescape(value)
    if name == "version"
      version = value
    elsif name == "platform"
      platform = value
    elsif name == "plugin"
      plugins << value
    end
  }
  platform = "x86_64-windows" if !platform && headers["user-agent"] =~ /Windows/
  platform = "x86_64-darwin" if !platform && headers["user-agent"] =~ /Macintosh/
  platform = "x86_64-linux" if !platform
  default_arguments = "--cachedir=cache --userdir #{@temporary_directory}/data --datadir #{@temporary_directory}/data --quiet --arch=#{platform} --json"

  system_log(request_number, "./lpm lite-xl install #{version} #{default_arguments}", "can't find lite-xl #{version} for #{platform}")
  lite_xl = JSON.parse(system_log(request_number, "./lpm lite-xl list #{default_arguments}", "can't list lite-xls"))["lite-xls"].select { |x| x["version"] == version }.first
  raise "can't find lite-xl installed local #{version}" if !lite_xl || !lite_xl["local_path"]
  FileUtils.cp_r(lite_xl["local_path"] + "/lite-xl", "#{@temporary_directory}/lite-xl")
  FileUtils.cp_r(lite_xl["local_path"] + "/data", "#{@temporary_directory}/data")
  system_log(request_number, "./lpm install #{plugins.join(' ')} #{default_arguments}", "can't find plugins")
  if platform =~ /windows/
    filename = "lite-xl-#{version}-#{platform}.zip"
    system_log(request_number, "cd #{@temporary_directory} && zip -r #{filename} lite-xl data && cd ..", "can't zip lite-xl")
  else
    filename = "lite-xl-#{version}-#{platform}.tar.gz"
    system_log(request_number, "tar -C #{@temporary_directory} -zcvf #{@temporary_directory}/#{filename} lite-xl data", "can't tar lite-xl")
  end
  file = File.open("#{@temporary_directory}/#{filename}", "rb")
  return [200, { "Content-Length" => File.size("#{@temporary_directory}/#{filename}"), "Content-Type" => "application/octet-stream", "Content-Disposition" => "attachment; filename=\"#{filename}\"" }, Proc.new {
    file.read(8192)
  }]
end

FileUtils.mkdir("cache") if !Dir.exist?("cache")
FileUtils.rm_rf(@temporary_directory)
FileUtils.mkdir(@temporary_directory)
system_log("wget https://github.com/lite-xl/lite-xl-plugin-manager/releases/download/latest/lpm.x86_64-linux -O lpm && chmod +x lpm", "can't get lpm") if !File.file?("lpm")
port = ARGV[0] || 4455
server = TCPServer.new(port)

log(0, "INFO", "Starting up TCP server on port #{port}...")
total_requests = 0
while session = server.accept
  total_requests += 1
  request_number = total_requests
  begin
    status = 200
    body = nil
    response_headers = {}
    begin 
      request = nil
      request_headers = {}
      Timeout::timeout(5, StandardError, "Read Timeout") {  
        request = session.gets(4096).chomp
        log(request_number, "INFO", request.chomp)
        while true
          line = session.gets(4096)
          break if line == "\r\n"
          captures = line.match /^([\w\-_]+)\s*:\s*(.*?)\r\n$/
          raise "can't parse header" unless captures && captures.size == 3
          request_headers[captures[1].downcase] = captures[2]
        end
      }
      method, full_path = request.split(' ')
      path, query = full_path.split('?')
      status, response_headers, body = handle_request(request_number, method, path, query || "", request_headers)
    rescue StandardError => e
      status = 500
      body = "500 Internal Server Error"
      response_headers = { "Content-Length" => body.size }
      log(request_number, "ERROR", "Internal Server Error: #{e.backtrace.join("\n")}.")
    end
    Timeout::timeout(5, StandardError, "Read Timeout") {  
      session.print "HTTP/1.1 #{status}\r\n"
      response_headers.each do |key, value|
        session.print "#{key}: #{value}\r\n"
      end
      session.print "\r\n"
    }
    begin
      if body.class == String
        Timeout::timeout(5, StandardError, "Read Timeout") {  
          session.print body
        }
      elsif body.class == Proc
        result = nil
        while true
          result = body.call()
          if result == nil then break end
          Timeout::timeout(5, StandardError, "Read Timeout") {  
            session.print result
          }
        end
        log(request_number, "INFO", "#{status} OK")
      else
        raise "Body not set correctly."
      end
    rescue StandardError => e
      log(request_number, "ERROR", "Error printing body: #{e}. Closing.")
    end
  rescue StandardError => e
    log(request_number, "ERROR", "Error in connection handling: #{e}. Closing.")
  end
  session.close
  FileUtils.rm_rf("#{@temporary_directory}/#{request_number}")
end
