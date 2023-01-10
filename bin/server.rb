#!/usr/bin/env ruby

require 'socket'
require 'cgi'
require 'json'
require 'fileutils'
require 'date'
require 'timeout'

@temporary_directory = "tmp"
@update_threshold = 3600
@max_header_size = 16*1024
@default_arguments = "--cachedir=cache --quiet --json"

codes = {
  "200" => "OK",          "204" => "No Content", 
  "400" => "Bad Request", "404" => "Not Found",  "431" => "Request Header Fields Too Large",
  "500" => "Internal Server Error"
}

def log(request_number, type, message)
  printf("[%8s][%s][%08d]: %s\n", type, DateTime.now.iso8601, request_number, message)
end

def system_log(request_number, cmd, exp)
  log(request_number, "SYSTEM", cmd)
  results = `#{cmd}`
  raise exp if $?.exitstatus != 0
  return results
end


def handle_download(request_number, query, headers) 
  version = "2.1.1-simplified"
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
  binary_extension = platform == "x86_64-windows" ? ".exe" : ""
  directory = "#{@temporary_directory}/#{request_number}"
  arguments = "#{@default_arguments} --arch=#{platform}  --userdir #{directory}/data --datadir #{directory}/data"

  raise RuntimeError.new(400) if [platform, version, *plugins].select { |x| x =~ /[^a-z\.\-_0-9]/ }.first

  system_log(request_number, "./lpm lite-xl install #{version} #{arguments}", "can't find lite-xl #{version} for #{platform}")
  lite_xl = JSON.parse(system_log(request_number, "./lpm lite-xl list #{arguments}", "can't list lite-xls"))["lite-xls"].select { |x| x["version"] == version }.first
  raise "can't find lite-xl installed local #{version}" if !lite_xl || !lite_xl["local_path"]
  FileUtils.cp_r(lite_xl["local_path"] + "/lite-xl#{binary_extension}", "#{directory}/lite-xl#{binary_extension}")
  FileUtils.cp_r(lite_xl["local_path"] + "/data/.", "#{directory}/data")
  system_log(request_number, "./lpm install #{plugins.join(' ')} #{arguments}", "can't find plugins")
  if platform =~ /windows/
    filename = "lite-xl-#{version}-#{platform}.zip"
    system_log(request_number, "cd #{directory} && zip -r #{filename} lite-xl#{binary_extension} data && cd ..", "can't zip lite-xl")
  else
    filename = "lite-xl-#{version}-#{platform}.tar.gz"
    system_log(request_number, "tar -C #{directory} -zcvf #{directory}/#{filename} lite-xl#{binary_extension} data", "can't tar lite-xl")
  end
  file = File.open("#{directory}/#{filename}", "rb")
  return [200, { "Content-Length" => File.size("#{directory}/#{filename}"), "Content-Type" => "application/octet-stream", "Content-Disposition" => "attachment; filename=\"#{filename}\"" }, Proc.new {
    file.read(8192)
  }]
end

def handle_request(request_number, method, path, query, headers) 
  if path == "/download"
    return handle_download(request_number, query, headers)
  elsif path == "/"
    body = File.read("index.html", encoding: "binary")
    return [200, { 'Content-Type' => 'text/html', "Content-Length" => body.size }, body]
  else
    raise RuntimeError.new(404)
  end
end

FileUtils.mkdir("cache") if !Dir.exist?("cache")
FileUtils.rm_rf(@temporary_directory)
FileUtils.mkdir(@temporary_directory)
system_log(0, "wget https://github.com/lite-xl/lite-xl-plugin-manager/releases/download/latest/lpm.x86_64-linux -O lpm && chmod +x lpm && ./lpm purge #{@default_arguments}", "can't get lpm") if !File.file?("lpm")
port = ARGV[0] || 4455
server = TCPServer.new(port)

last_update = DateTime.now

log(0, "INFO", "Starting up TCP server on port #{port}...")
total_requests = 0
while session = server.accept
  if DateTime.now - last_update > @update_threshold
    last_update = DateTime.now
    system_log(0, "./lpm update", "can't update")
    system_log(0, "./build.rb", "can't build")
  end
  total_requests += 1
  request_number = total_requests
  FileUtils.mkdir("#{@temporary_directory}/#{request_number}")
  begin
    status = 200
    body = nil
    response_headers = {}
    begin 
      request = nil
      request_headers = {}
      total_bytes = 0
      Timeout::timeout(5, StandardError, "Read Timeout") {  
        request = session.gets(4096).chomp
        log(request_number, "INFO", request.chomp)
        total_bytes += request.size
        while true
          line = session.gets(4096)
          total_bytes += line.size
          break if line == "\r\n"
          raise RuntimeError.new(431) if total_bytes > @max_header_size
          captures = line.match /^([\w\-_]+)\s*:\s*(.*?)\r\n$/
          raise "can't parse header" unless captures && captures.size == 3
          request_headers[captures[1].downcase] = captures[2]
        end
      }
      method, full_path = request.split(' ')
      path, query = full_path.split('?')
      status, response_headers, body = handle_request(request_number, method, path, query || "", request_headers)
    rescue StandardError => e
      code = codes[e.message] ? e.message : "500"
      status, response_headers, body = [code.to_i, { "Content-Length" => codes[code].size + 4 }, code + " " + codes[code]]
      log(request_number, "ERROR", "#{e.backtrace.join("; ")}") if code == "500"
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
      else
        raise "Body not set correctly."
      end
      log(request_number, "INFO", "#{status} " + (codes[status.to_s] || "Unknown"))
    rescue StandardError => e
      log(request_number, "ERROR", "Error printing body: #{e}. Closing.")
    end
  rescue StandardError => e
    log(request_number, "ERROR", "Error in connection handling: #{e}. Closing.")
  end
  session.close
  FileUtils.rm_rf("#{@temporary_directory}/#{request_number}")
end
