#!/usr/bin/env ruby

# == Synopsis
#
# caching_proxy: Caching proxy server which will cache GET and POST requests.
#
# Rob Holland <rob@inversepath.com>
#
# == Usage
#
# caching_proxy [OPTION]
#
# --help:
#   show this help message
# --cache_directory: <directory>
#   set the directory to use for caching files
# --host, -h: <host>
#   host to listen on (default: 127.0.0.1)
# --port, -p: <port>
#   port to listen on (default: 8080)
#
# == Notes
#
# The caching is keyed solely on the URL and the query data. Be careful to
# ensure that the same URL does not generate different content depending on
# cookies or other non-URL based context, as you would only ever see the first
# content fetched.
#
# For example, given a site that records a user's search query in a cookie and
# then provides "next page" links of the form
# "http://search.example.com/page=2", the content cached when following that
# link would then be returned from the cache for the second page of any search
# query, the proxy has no way to know the content should differ.
#
# For sites that behave this way, you should experiment with appending the
# navigation query terms onto the URL you are using to perform the search, for
# example: "http://search.example.com/search_query=rabbit&page=2". If the site
# accepts this then you should adjust the URLs you are fetching to use this
# syntax, the caching proxy will properly cache pages as expected. If you
# cannot get find a way to get unique URLs for each page of content, you
# should not use this proxy.
#
# Caching POST requests is not usually implemented in caching proxies  and
# verges on being "wrong". The reason I have implemented it is that a large
# number of websites use POST when they should be using GET, for example to
# drive search interfaces. The RFCs state POST requests should be used when
# there can be side effects from the requested action, such as
# addition/deletion/modification of some server-side data. As searching is
# read-only, search requests should really be GETs. Given that it's not
# feasible to get the webmasters to correct their sites, I've implemented POST
# caching to cover this case. Be sure that you are not using this proxy for
# POST queries which do have side effects however, the cache would interfere
# and potentionally cause data loss/corruption.

require 'webrick/httpproxy'
require 'digest/md5'
require 'getoptlong'
require 'rdoc/usage'

module WEBrick
  # This is copy+paste hack of WEBrick::HTTPProxyServer. It's unfortunate
  # that I had to copy such a large function for a reasonable small change. As
  # the code is not cleanly separated I had no choice. The comments are a mix
  # of mine and the original comments from the code.
  class HTTPCachingProxyServer < HTTPProxyServer
    def initialize(config)
      @cache_directory = config.delete(:CacheDirectory)
      raise ArgumentError, "No cache directory specified" unless @cache_directory
      super(config)
    end

    def proxy_service(req, res)
      # Proxy Authentication
      proxy_auth(req, res)

      # Create Request-URI to send to the origin server
      uri  = req.request_uri
      path = uri.path.dup
      path << "?" << uri.query if uri.query

      cache_header = "#{req.request_method} #{path} #{req.body}"
      cache_key = Digest::MD5.hexdigest(cache_header)
      cache_dir = "#{@cache_directory}/#{uri.host}:#{uri.port}"
      cache_file = "#{cache_dir}/#{cache_key}"

      response = nil

      # Serve the cached response if it exists
      if File.exists?(cache_file)
        response = Marshal.load(File.new(cache_file).read)
      else # No cached version, do a real request
        # Choose header fields to transfer
        header = Hash.new
        choose_header(req, header)
        set_via(header)

        # select upstream proxy server
        if proxy = proxy_uri(req, res)
          proxy_host = proxy.host
          proxy_port = proxy.port
          if proxy.userinfo
            credentials = "Basic " + [proxy.userinfo].pack("m*")
            credentials.chomp!
            header['proxy-authorization'] = credentials
          end
        end

        begin
          http = Net::HTTP.new(uri.host, uri.port, proxy_host, proxy_port)
          http.start{
            if @config[:ProxyTimeout]
              ##################################   these issues are 
              http.open_timeout = 30   # secs  #   necessary (maybe bacause
              http.read_timeout = 60   # secs  #   Ruby's bug, but why?)
              ##################################
            end
            case req.request_method
            when "GET"  then response = http.get(path, header)
            when "POST" then response = http.post(path, req.body || "", header)
            when "HEAD" then response = http.head(path, header)
            else
              raise HTTPStatus::MethodNotAllowed,
                "unsupported method `#{req.request_method}'."
            end
          }
        rescue => err
          logger.debug("#{err.class}: #{err.message}")
          raise HTTPStatus::ServiceUnavailable, err.message
        end

        # Cache the response
        FileUtils.mkdir_p(cache_dir)
        File.open(cache_file, 'w') do |file|
          file << Marshal.dump(response)
        end
      end
  
      # Persistent connction requirements are mysterious for me.
      # So I will close the connection in every response.
      res['proxy-connection'] = "close"
      res['connection'] = "close"

      # Convert Net::HTTP::HTTPResponse to WEBrick::HTTPProxy
      res.status = response.code.to_i
      choose_header(response, res)
      set_cookie(response, res)
      set_via(res)
      res.body = response.body

      # Process contents
      if handler = @config[:ProxyContentHandler]
        handler.call(req, res)
      end
    end
  end
end

options = GetoptLong.new(
  ['--cache-directory', '-d', GetoptLong::REQUIRED_ARGUMENT],
  ['--host', '-h', GetoptLong::REQUIRED_ARGUMENT],
  ['--port', '-p', GetoptLong::REQUIRED_ARGUMENT],
  ['--help', GetoptLong::NO_ARGUMENT]
)

cache_directory = File.dirname(__FILE__) + '/.proxy_cache'
host = '127.0.0.1'
port = '8080'

options.each do |option, arg|
  case option
  when '--cache-directory'
    cache_directory = File.expand_path(arg)
  when '--host'
    host = arg
  when '--port'
    port = arg.to_i
  when '--help'
    RDoc::usage
  end
end

proxy = WEBrick::HTTPCachingProxyServer.new(
  :CacheDirectory => cache_directory,
  :BindAddress => host,
  :Port => port
)
trap('INT') { proxy.shutdown }
proxy.start
