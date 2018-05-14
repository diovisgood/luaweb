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
- Supports persistent connections (i.e. 'Connection: keep-alive').
- Supports Proxy for both HTTP (via *GET*) and HTTPS (via *CONNECT*).
- Supports *basic* authentication method for servers and proxies.
- Transparently manages a pool of recently used connections. Reuses old or recreates new connections on the fly.
- Offers quick functions: *web.get*, *web.post*, *web.head* for simple and robust work.
- Allows low-level access via *web.getConnection* and *web.request* to implement any desired task.
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

## Proxy

  ```
  web.PROXY = 'https://92.53.73.138:8118'
  result, code, headers, status = assert( web.get('http://bbc.com/') )
  print(tostring(result):sub(1, 100))
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

# Implementation Notes

This module has not been heavily tested. At the end of module you may find unit tests and many of them aren't written yet!
Any help or comments are appreciated!

Here is what could be added to make it better:
- Simple cookies support.
- Digest authentication method.
