-----------------------------------------------------------------------------
--[[
 
HTTP and HTTPS simple browser for Lua

Copyright (C) 2018 Pavel B. Chernov (pavel.b.chernov@gmail.com)

LICENSE (MIT):

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

]]
-----------------------------------------------------------------------------

local socket = require 'socket'
local socket_url = require 'socket.url'
local socket_headers = require 'socket.headers'
local ltn12 = require 'ltn12'
local mime = require 'mime'
local ssl = require 'ssl'

local web = {}

-----------------------------------------------------------------------------
-- Default constants
-----------------------------------------------------------------------------

-- Default connection timeout in seconds
web.TIMEOUT = 60
-- Maximum number of redirects
web.MAX_REDIRECTS = 5
-- Default request user agent field
web.USERAGENT = socket._VERSION
-- Default SSL/TLS parameters
web.SSL = {
  protocol = 'any',
  options  = { 'all', 'no_sslv2', 'no_sslv3' },
  verify   = 'none',
  mode     = 'client',
}

-- Supported schemes
local SCHEMES = { http = true, https = true, }

-- Default ports
local HTTP_PORT = 80
local HTTPS_PORT = 443

-----------------------------------------------------------------------------
-- Extra sources and sinks
-----------------------------------------------------------------------------

local function webLog(...)
  if web.logfile then
    web.logfile:write(...)
    web.logfile:write('\n')
  end
end -- function webLog

local function receiveHeaders(sock, headers)
  headers = headers or {}
  local line, name, value, err
  -- Read headers line by line until blank
  while true do
    -- Read next line
    line, err = sock:receive('*l')
    if (not line) then return nil, err end
    if (line == '') then break end
    -- Get field and value
    name, value = line:match('^(.-):%s*(.*)')
    if (not name) or (not value) then
      return nil, 'Invalid reponse headers: '..tostring(line)
    end
    -- Save field and value in table
    name = name:lower()
    if headers[name] then
      headers[name] = headers[name] .. ', ' .. value
    else
      headers[name] = value
    end
  end
  return headers
end -- function receiveHeaders

socket.sourcet['http-chunked'] = function(sock, headers)
  return setmetatable({
    getfd = function() return sock:getfd() end,
    dirty = function() return sock:dirty() end
  }, {
    __call = function()
      -- get chunk size, skip extention
      local line, err = sock:receive('*l')
      if err then return nil, err end
      local size = tonumber(string.gsub(line, ';.*', ''), 16)
      if (not size) then return nil, 'web: chunked: Invalid chunk size' end
      -- was it the last chunk?
      if (size > 0) then
        -- if not, get chunk and skip terminating CRLF
        local chunk, err = sock:receive(size)
        if chunk then sock:receive(2) end
        return chunk, err
      else
        -- if it was, read trailers into headers table
        headers, err = receiveHeaders(sock, headers)
        if (not headers) then return nil, err end
      end
    end
  })
end

socket.sinkt['http-chunked'] = function(sock)
  return setmetatable({
    getfd = function() return sock:getfd() end,
    dirty = function() return sock:dirty() end
  }, {
    __call = function(self, chunk, err)
      if (not chunk) then return sock:send('0\r\n\r\n') end
      local size = string.format('%X\r\n', string.len(chunk))
      return sock:send(size ..  chunk .. '\r\n')
    end
  })
end

-----------------------------------------------------------------------------
-- Low level HTTP(S) Connection  API
-----------------------------------------------------------------------------

local Connection = {}

local Pool = {}

web.getConnection = socket.protect(function(request)
  -- Try to reuse previous connections
  local host_port = tostring(request.host)..':'..tostring(request.port)
  local address = tostring(request.scheme)..'://'..host_port
  if web.logfile then webLog('web.getConnection: ', address) end
  if Pool[address] then
    if web.logfile then webLog('Reusing connection ', address) end
    return Pool[address]
  end
  -- Create TCP socket
  local sock = socket.try(socket.tcp())
  -- Initialize connection
  local conn = { sock = sock }
  setmetatable(conn, { __index = Connection } )
  -- Create finalized try to ensure 
  conn.try = socket.newtry(function() conn:close() end)
  -- Set timeout before connecting
  conn.try(sock:settimeout(web.TIMEOUT))
  -- Establish connection to a remote host
  if request.proxy or web.PROXY then
    -- Connect to a host through proxy
    local proxy = socket_url.parse(request.proxy or web.PROXY)
    proxy.port = (proxy.port or 3128)
    conn.try(sock:connect(proxy.host, proxy.port))
    if web.logfile then webLog('Connected to proxy ', proxy.host, ':', proxy.port) end
    -- For HTTPS use CONNECT command
    if (request.scheme == 'https') then
      -- Prepare CONNECT command
      local text = 'CONNECT '..host_port..' HTTP/1.1\r\n'
        ..'Host: '..host_port..'\r\n'
        ..'Proxy-Connection: keep-alive\r\n'
        ..'User-Agent: '..tostring(web.USERAGENT)..'\r\n'
      -- Apply proxy authorization if needed
      if proxy.user and proxy.password then
        text = text .. 'Proxy-Authorization: Basic '
          ..(mime.b64(socket_url.unescape(proxy.user)..':'..socket_url.unescape(proxy.password)))
          ..'\r\n'
      end
      text = text .. '\r\n'
      -- Send command
      conn.try(sock:send(text))
      -- Read proxy response
      local code, status = conn:receiveStatusLine()
      if (not code) or (code ~= 200) then
        if web.logfile then webLog('Failed to connect through proxy: ', status) end
        conn.try(nil, status)
      end
    end
  else
    -- Connect directly to host
    conn.try(sock:connect(request.host, request.port))
  end
  if web.logfile then webLog('Connected to host ', host_port) end
  -- Establish SSL/TLS connection
  if (request.scheme == 'https') then
    conn.sock = conn.try(ssl.wrap(sock, web.SSL))
    conn.sock:sni(request.host)
    conn.try(conn.sock:dohandshake())
    if web.logfile then webLog('Established SSL connection to ', host_port) end
  end
  -- Save connection in a pool for future reuse
  Pool[address] = conn
  return conn
end) -- function web.getConnection

function web.reset()
  if web.logfile then webLog('Closing all connections in pool') end
  for address, conn in pairs(Pool) do
    Pool[address] = nil
    conn.sock:close()
  end
end -- function web.reset

function Connection:close()
  -- Remove connection from Pool
  for address, conn in pairs(Pool) do
    if (conn == self) then
      if web.logfile then webLog('Erasing connection ', address, ' from pool') end
      Pool[address] = nil
      break
    end
  end
  -- Close socket
  return self.sock:close()
end -- function Connection:close

function Connection:sendRequestLine(method, uri)
  return self.try(self.sock:send(string.format('%s %s HTTP/1.1\r\n', method, uri)))
end -- function Connection:sendRequestLine

function Connection:sendHeaders(headers)
  local canonic = socket_headers.canonic
  local text = '\r\n'
  for k, v in pairs(headers) do
    text = (canonic[k] or k) .. ': ' .. v .. '\r\n' .. text
  end
  self.try(self.sock:send(text))
  return 1
end -- function Connection:sendHeaders

function Connection:sendBody(headers, source, step)
  source = source or ltn12.source.empty()
  step = step or ltn12.pump.step
  -- if we don't know the size in advance, send chunked and hope for the best
  local mode = 'http-chunked'
  if headers['content-length'] then mode = 'keep-open' end
  return self.try(ltn12.pump.all(source, socket.sink(mode, self.sock), step))
end -- function Connection:sendBody

function Connection:receiveStatusLine()
  local status = self.try(self.sock:receive(5))
  -- Identify HTTP/0.9 responses, which do not contain a status line
  -- (RFC recommendations)
  if (status ~= 'HTTP/') then return nil, status end
  -- otherwise proceed reading a status line
  status = self.try(self.sock:receive('*l', status))
  local code = string.match(status, 'HTTP/%d*%.%d* (%d%d%d)')
  return self.try(tonumber(code), status)
end -- function Connection:receiveStatusLine

function Connection:receiveHeaders(headers)
  return self.try(receiveHeaders(self.sock, headers))
end -- function Connection:receiveHeaders

function Connection:receiveBody(headers, sink, step)
  sink = sink or ltn12.sink.null()
  step = step or ltn12.pump.step
  local length = tonumber(headers['content-length'])
  local encoding = headers['transfer-encoding']
  local mode = 'until-closed'
  if encoding and (encoding ~= 'identity') then
    mode = 'http-chunked'
  elseif tonumber(headers['content-length']) then
    mode = 'by-length'
  end
  return self.try(ltn12.pump.all(socket.source(mode, self.sock, length), sink, step))
end -- function Connection:receiveBody

function Connection:receive09Body(status, sink, step)
  local source = ltn12.source.rewind(socket.source('until-closed', self.sock))
  source(status)
  return self.try(ltn12.pump.all(source, sink, step))
end -- function Connection:receive09Body

-----------------------------------------------------------------------------
-- High level HTTP API
-----------------------------------------------------------------------------

local function adjustRequest(request)
  -- Check scheme
  if (type(request.scheme) ~= 'string') then
    request.scheme = 'http'
  elseif (not SCHEMES[request.scheme]) then
    -- Raise error
    socket.try(nil, 'adjustRequest: scheme is not supported: ' .. tostring(request.scheme))
  end
  -- Check host
  if (type(request.host) ~= 'string') or (request.host == '') then
    -- Raise error
    socket.try(nil, 'adjustRequest: invalid host "' .. tostring(request.host) .. '"')
  end
  -- Check port
  if (type(request.port) ~= 'number') or (request.port < 0)
  or (math.floor(request.port) ~= request.port) then
    if (request.scheme == 'https') then
      request.port = HTTPS_PORT
    else
      request.port = HTTP_PORT
    end
  end
  -- Check path
  if (type(request.path) ~= 'string') or (request.path == '') then
    request.path = '/'
  end
  -- Check or construct URI
  if (type(request.uri) ~= 'string') or (request.uri == '') then
    -- If we use proxy and not HTTPS connection
    -- then we should request whole address. I.e.:
    --  GET http://host:port/path?query HTTP/1.1
    -- Otherwise we should request only path part:
    --  GET /path?query HTTP/1.1
    local uri = request
    if (not (request.proxy or web.PROXY)) or (request.scheme == 'https') then
      uri = {
        path = request.path,
        params = request.params,
        query = request.query,
        fragment = request.fragment
      }
    end
    request.uri = socket_url.build(uri)
  end
  -- Adjust headers in request
  -- Initialize default headers
  local headers = {
    ['user-agent'] = tostring(web.USERAGENT),
    ['host'] = request.host,  -- string.gsub(request.authority, '^.-@', ''),
    ['connection'] = 'keep-alive',
    ['te'] = 'trailers',
  }
  -- Add authentication header if needed
  if (type(request.user) == 'string') and (type(request.password) == 'string') then
    headers['authorization'] =
      'Basic '..(mime.b64(socket_url.unescape(request.user)..':'.. socket_url.unescape(request.password)))
  end
  -- Add proxy authentication header if needed and if not HTTPS
  if (request.proxy or web.PROXY) and (request.scheme ~= 'https') then
    local proxy = socket_url.parse(request.proxy or web.PROXY)
    if (type(proxy.user) == 'string') and (type(proxy.password) == 'string') then
      headers['proxy-authorization'] =
        'Basic '..(mime.b64(socket_url.unescape(proxy.user)..':'..socket_url.unescape(proxy.password)))
    end
  end
  -- Override with user headers
  if (request.headers) then
    for k, v in pairs(request.headers) do
      local k_lower = k:lower()
      if headers[k_lower] then
        headers[k_lower] = v
      else
        headers[k] = v
      end
    end -- for request.headers
  end -- if request.headers
  request.headers = headers
  return request
end -- function adjustRequest

local function shouldRedirect(request, code, headers)
  local location = headers.location
  if (not location) then return false end
  location = string.gsub(location, '%s', '')
  if (location == '') then return false end
  local scheme = string.match(location, '^([%w][%w%+%-%.]*)%:')
  if scheme and (not SCHEMES[scheme]) then return false end
  return (request.redirect ~= false)
    and (code == 301 or code == 302 or code == 303 or code == 307)
    and (not request.method or request.method == 'GET' or request.method == 'HEAD')
    and (not request.n_redirects or request.n_redirects < web.MAX_REDIRECTS)
end -- function shouldRedirect

local function shouldReceiveBody(request, code)
  if (request.method == 'HEAD') then return nil end
  if (code == 204) or (code == 304) then return nil end
  if (code >= 100) and (code < 200) then return nil end
  return 1
end -- function shouldReceiveBody

local function shouldKeepAlive(request_headers, response_headers)
  local f_keep_alive = true
  local timeout, max
  local v
  -- Check request
  if (type(request_headers) == 'table') then
    if request_headers.connection then
      v = string.lower(tostring(request_headers.connection))
      v = v:match('%s*([^%s,]+)%s*')
      if v and (v == 'close') then
        f_keep_alive = false
      end
    end -- if connection
  end -- if request_headers
  -- Check response
  if (type(response_headers) == 'table') then
    if response_headers.connection then
      v = string.lower(tostring(response_headers.connection))
      v = v:match('%s*([^%s,]+)%s*')
      if v and (v == 'close') then
        f_keep_alive = false
      end
    end -- if connection
    if response_headers['keep-alive'] then
      v = string.lower(tostring(response_headers['keep-alive']))
      timeout = tonumber( v:match('timeout%s*=%s*([%d%.]+)') )
      max = tonumber( v:match('max%s*=%s*(%d+)') )
    end -- if connection
  end -- for response_headers
  return f_keep_alive, timeout, max
end -- function shouldKeepAlive

local function performRedirect(request, location)
  -- Force redirect URL to be absolute
  local new_url = socket_url.absolute(request.url, location)
  local new_request = socket_url.parse(new_url)
  -- Update request fields
  request.url = new_url
  request.scheme = new_request.scheme
  request.host = new_request.host
  request.port = new_request.port
  request.authority = new_request.authority
  request.path = new_request.path or request.path
  request.n_redirects = (request.n_redirects or 0) + 1
  -- Perform new request
  local result, code, headers, status = web.request(request)
  -- Ensure there is location in response headers
  headers = headers or {}
  headers.location = headers.location or location
  return result, code, headers, status
end -- function performRedirect

local performRequest = socket.protect(function(conn, request)
  -- Send HTTP request line
  conn:sendRequestLine(request.method, request.uri)
  if web.logfile then webLog(request.method, ' ', request.uri) end
  
  -- Send request headers
  conn:sendHeaders(request.headers)
  --if web.logfile then for k, v in pairs(request.headers) do webLog(k, ': ', v) end end
  
  -- Send body if needed
  if request.source then
    conn:sendBody(request.headers, request.source, request.step)
  end
  
  -- Receive server status line
  local code, status = conn:receiveStatusLine()
  if web.logfile then webLog(status) end
  
  -- For HTTP/0.9 server simply get the body and we are done
  if (not code) then
    conn:receive09body(status, request.sink, request.step)
    return 1, 200
  end
  
  -- Receive response headers
  local headers
  -- Ignore any 100-continue messages
  while (code == 100) do
    headers = conn:receiveHeaders()
    code, status = conn:receiveStatusLine()
  end
  headers = conn:receiveHeaders()
  --if web.logfile then for k, v in pairs(headers) do webLog(k, ': ', v) end end
  
  -- at this point we should have a honest reply from the server
  -- we can't redirect if we already used the source, so we report the error
  if shouldRedirect(request, code, headers) and (not request.source) then
    if web.logfile then webLog('Redirecting to ', headers.location) end
    return performRedirect(request, headers.location)
  end
  
  -- Receive response body if needed
  if shouldReceiveBody(request, code) then
    conn:receiveBody(headers, request.sink, request.step)
  end
  
  -- Increment connection requests counter
  conn.n_requests = (conn.n_requests or 0) + 1
  
  -- Check connection keep-alive
  local f_keep_alive, timeout, max_requests = shouldKeepAlive(request.headers, headers)
  if f_keep_alive then
    conn.timeout = timeout
    conn.max_requests = max_requests
  end
  -- Close connection if needed
  if (not f_keep_alive) or (conn.max_requests and conn.n_requests >= conn.max_requests) then
    conn:close()
  end
  
  return 1, code, headers, status
end) -- function performRequest

-----------------------------------------------------------------------------
-- Public API
-----------------------------------------------------------------------------

function web.request(request)
  if web.logfile then webLog('web.request ', tostring(request.method), ' ', tostring(request.url)) end
  
  -- Check and adjust request fields
  request = adjustRequest(request)
  
  local conn, result, code, headers, status
  
  -- Get new or existing connection for request
  conn, code = web.getConnection(request)
  if conn then
    -- First try
    result, code, headers, status = performRequest(conn, request)
  end
  
  if (not result)
  and ((code == 'closed') or (code == 'timeout') or (code == 'wantread') or (code == 'wantwrite')) then
    -- Close connection and remove it from Pool
    if conn then conn:close() end
    -- Open new connection
    conn, code = web.getConnection(request)
    if (not conn) then return nil, code end
    -- Second try
    result, code, headers, status = performRequest(conn, request)
  end
  
  return result, code, headers, status
end -- function web.request

function web.call(method, url, body, f_skip_response_body)
  -- Check parameters
  assert(type(method) == 'string', 'web.call: Invalid method type!')
  method = method:upper()
  assert(method == 'HEAD' or method == 'GET' or method == 'POST'
    or method == 'PUT' or method == 'DELETE',
    'web.call: Invalid method value!')
  assert(type(url) == 'string', 'web.call: Invalid url parameter!')
  -- Prepare request
  local target = {}
  local request = socket_url.parse(url)
  request.method = method
  request.url = url
  if (type(body) == 'string') then
    request.source = ltn12.source.string(body)
    request.headers = {
      ['content-length'] = string.len(body),
      ['content-type'] = 'application/x-www-form-urlencoded'
    }
  end
  request.sink = ltn12.sink.table(target)
  request.target = target
  -- Perform request
  local result, code, headers, status = web.request(request)
  if (not result) or f_skip_response_body then
    return result, code, headers, status
  end
  -- Analyse response data
  if (type(target) == 'table') then
    result = table.concat(target)
  else
    result = target
  end
  -- Return result
  return result, code, headers, status
end -- function web.call

function web.head(url)
  return web.call('HEAD', url, nil, true)
end -- function web.get

function web.get(url)
  return web.call('GET', url)
end -- function web.get

function web.post(url, body)
  return web.call('POST', url, body)
end -- function web.post

function web.put(url, body)
  return web.call('PUT', url, body)
end -- function web.put

function web.delete(url)
  return web.call('DELETE', url)
end -- function web.delete

-- Additional proxy function to encode special symbols in URL with % codes
web.escape = socket_url.escape

-- Additional proxy function to decode special % codes in URL back to symbols
web.unescape = socket_url.unescape

-- Check if running from console
local info = debug.getinfo(2)
if info and (info.name or (info.what ~= 'C')) then
  return web
end

-----------------------------------------------------------------------------
-- Unit Tests
-----------------------------------------------------------------------------

-- Enable logging to stdout
web.logfile = io.stdout

local function test(url)
  local result, code, headers, status = web.get(url)
  if (not result) then
    print('Failed web.get: '..tostring(code))
    return
  end
  if (type(result) == 'string') then
    print(result:sub(1, 50)..(result:len() > 50 and '...' or ''))
  else
    error('Invalid result type: '..type(result))
  end
  print('Headers:')
  for k, v in pairs(headers) do
    print(' '..tostring(k)..'\t:',tostring(v):sub(1,40))
  end
end -- function test

-- Test redirect
test('http://ya.ru') -- redirects to https://ya.ru/

-- Test for connection reusing
test('https://ya.ru/')

-- Test HTTPS through proxy via CONNECT method
web.reset()
web.PROXY = 'https://45.249.9.22:53281'
test('https://ya.ru/')

test('https://meduza.io/')


-- Test HTTP through proxy via GET method
-- Test HTTP request with multiple chunks received
test('http://export.finam.ru/SPFB.SBRF-9.17_170501_170930.txt?market=14&em=459548&code=SPFB.SBRF-9.17&apply=0&df=1&mf=4&yf=2017&from=01.05.2017&dt=30&mt=8&yt=2017&to=30.09.2017&p=2&f=SPFB.SBRF-9.17_170501_170930&e=.txt&cn=SPFB.SBRF-9.17&dtf=2&tmf=4&MSOR=1&mstime=on&mstimever=1&sep=1&sep2=1&datf=5&at=1')

-- TODO: Test HTTP HEAD request

-- TODO: Test HTTP POST request

-- TODO: Test HTTPS through proxy with authorization via CONNECT method

-- TODO: Test HTTP through proxy with authorization via GET method

-- TODO: Test HTTP with authorization

-- TODO: Test HTTPS with authorization

-- TODO: Test HTTP with authorization through proxy with authorization via GET method

-- TODO: Test HTTPS with server certificate check

-- TODO: Test HTTPS with client certificate and server certificate check
