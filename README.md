# luaweb
HTTP and HTTPS simple browser for Lua

Copyright (C) 2018 Pavel B. Chernov (pavel.b.chernov@gmail.com)

## LICENSE (MIT):

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

## Benefits
- Supports both HTTP and HTTPS connections.
- Supports redirects. You can adjust max redirects.
- Supports Proxy for both HTTP (via *GET*) and HTTPS (via *CONNECT*).
- Supports *basic* authentication method for servers and proxies.
- Supports persistent connections (i.e. 'Connection: keep-alive').
- Transparently manages a pool of recently used connections. Reuses old or recreates new connections on the fly.
- Offers quick functions: *web.head*, *web.get*, *web.post*, *web.put* and *web.delete* for simple and robust work.
- Allows low-level access via *web.getConnection*, *web.call* and *web.request* to implement any desired task.
- Supports logging into specified file for debugging.

# Usage

## Simple GET request

  ```
  local web = require 'web'
  local result, code, headers, status = assert( web.get('https://ya.ru/') )
  print(tostring(result):sub(1, 100))
  ```

## Simple POST request

  ```
  local body = 'Some text'
  result, code, headers, status = assert( web.post('https://ya.ru/', body) )
  print(tostring(result):sub(1, 100))
  ```
  
## Simple PUT request

  ```
  local body = 'Some text'
  result, code, headers, status = assert( web.put('https://ya.ru/file1.txt', body) )
  print(tostring(result):sub(1, 100))
  ```
  
## Simple DELETE request

  ```
  local body = 'Some text'
  result, code, headers, status = assert( web.delete('https://ya.ru/file1.txt') )
  print(tostring(result):sub(1, 100))
  ```

## HTTP Through Proxy

  ```
  web.PROXY = 'https://92.53.73.138:8118' -- This line should be changed. Please specify any working proxy!
  result, code, headers, status = assert( web.get('http://bbc.com/') )
  print(tostring(result):sub(1, 100))
  ```

## HTTPS Through Proxy via CONNECT

  ```
  web.PROXY = 'https://92.53.73.138:8118' -- This line should be changed. Please specify any working proxy!
  result, code, headers, status = assert( web.get('https://ya.ru/') )
  print(tostring(result):sub(1, 100))
  ```

## Low Level Non-standard Request Headers via *web.call*

In the following example we perform a special POST request with non-standard HTTP headers *Key* and *Sign*.
Note that you may specify any headers you want. If you specify some standard headers (like *User-Agent:*)
- they will override default headers.
Whereas non-standard headers are just added "as is".
  ```
  -- Construct message
  poloniex.nonce = (poloniex.nonce or 0) + 1
  local msg = 'command=returnCompleteBalances&nonce='..tostring(poloniex.nonce)
  
  -- Construct headers
  local request_headers = {
    Key = poloniex.public_key,
    Sign = sha1.hmac(poloniex.secret_key, msg),
  }
  -- Perform Web request
  -- Check returned body and code
  result, code, headers, status =
    web.call('POST', url, msg, request_headers)
  if (not result) or (code ~= 200) then return nil, errorMsg(url, result, code, headers, status) end
  ```

## SSL/TLS with manual parameters

  *web.SSL* table holds default parametes for luasec. By default it does not verify cerificates (*verify = none*). But you may change these parameters directly to what you need:
  
  ```
  web.SSL.key = "/root/client.key"
  web.SSL.certificate = "/root/client.crt"
  web.SSL.cafile = "/root/ca.crt"
  web.SSL.verify = 'peer'
  
  result, code, headers, status = assert( web.get('https://server-with-certificate.com/') )
  print(tostring(result):sub(1, 100))
  ```

See: https://github.com/brunoos/luasec/wiki/LuaSec-0.7 for more details about SSL/TLS parameters

## Adjusting Parameters

  ```
  web.TIMEOUT = 60                -- Adjust default connection timeout.
  web.MAX_REDIRECTS = 5           -- Maximum number of redirects to follow.
  web.USERAGENT = socket._VERSION -- Setup any string for User-Agent header.
  web.SSL = { ... }               -- Setup any LuaSec fields and certificates.
  ```

## Logging for Debug

  ```
  -- Enable logging to stdout
  web.logfile = io.stdout
  result, code, headers, status = assert( web.get('https://ya.ru/') )
  print(tostring(result):sub(1, 100))
  ```
You see the following output:
  ```
web.request GET https://ya.ru/
web.getConnection: https://ya.ru:443
GET /
HTTP/1.1 200 Ok
<!DOCTYPE html><html class="i-ua_js_no i-ua_css_st...
  ```


# Implementation Notes

This module has not been heavily tested. At the end of module you may find unit tests and many of them aren't written yet!
Any help or comments are appreciated!

Here is what could be added to make it better:
- Simple cookies support.
- Digest authentication method.
