#!/usr/bin/env ruby

require 'json'

system("wget https://github.com/lite-xl/lite-xl-plugin-manager/releases/download/latest/lpm.x86_64-linux -O lpm && chmod +x lpm") if !File.file?("lpm")
lite_xls = JSON.parse(`./lpm lite-xl list --json --cachedir=cache`)["lite-xls"].select { |x| x['status'] == 'available' }.map { |x|
  "<option value='#{x["version"]}'>#{x["version"]}</option>"
}.join("\n")
has_plugin = {}
plugins = JSON.parse(`./lpm plugin list --json --cachedir=cache`)["plugins"].sort { |a,b| (a["name"] || a["id"]) + b["version"] <=> (b["name"] || b["id"]) + a["version"] }.map { |x|
  if !has_plugin[x["id"]] 
    has_plugin[x["id"]] = 1
    "<li title='#{x["description"]}'><label for='#{x["id"]}'><input class='query-set' data-dependencies='#{x["dependencies"]}' type='checkbox' id='#{x["id"]}' name='plugin' value='#{x["id"]}'><span class='name'>#{x["name"] || x["id"]}</span><span class='version'>#{x["version"]}</span></label></li>"
  end
}.join("\n")

File.write("index.html", File.read("index.tmpl").gsub(/{{\s*versions\s*}}/, lite_xls).gsub(/{{\s*plugins\s*}}/, plugins))
