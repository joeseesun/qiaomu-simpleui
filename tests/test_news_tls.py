"""Exercise the shipped news request against verified and rejected loopback TLS."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import hashlib
import json
import os
import ssl
import subprocess
import sys
import tempfile
import threading
import zipfile

from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / 'simpleui.koplugin'
CA = PLUGIN / 'data/ca'
metadata = json.loads((CA / 'bundle.json').read_text())
pem = (CA / 'cacert.pem').read_bytes()
assert hashlib.sha256(pem).hexdigest() == metadata['sha256']
assert pem.count(b'-----BEGIN CERTIFICATE-----') == metadata['certificates']
context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
preloaded = context.cert_store_stats()['x509']
context.load_verify_locations(cafile=str(CA / 'cacert.pem'))
assert context.cert_store_stats()['x509'] - preloaded == metadata['certificates']
assert metadata['checksum_url'] == metadata['source_url'] + '.sha256'
assert metadata['license'] == 'MPL-2.0'
assert 'Mozilla Public License Version 2.0' in (CA / 'LICENSE-MPL-2.0.txt').read_text()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"entries":[]}'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


@contextmanager
def https_server(cert, key):
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'https://localhost:{server.server_port}'
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


with tempfile.TemporaryDirectory() as directory:
    tmp = Path(directory)
    fixture_plugin = tmp / "Kindle's plugins" / 'simpleui.koplugin'
    fixture_ca = fixture_plugin / 'data/ca/cacert.pem'
    fixture_ca.parent.mkdir(parents=True)

    def openssl(*args):
        result = subprocess.run(['openssl', *args], cwd=tmp, capture_output=True)
        assert result.returncode == 0, result.stderr.decode()

    for name in ['trusted', 'untrusted']:
        openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
                '-subj', f'/CN=SimpleUI Test {name} CA',
                '-keyout', f'{name}.key', '-out', f'{name}.pem',
                '-addext', 'basicConstraints=critical,CA:TRUE')
    openssl('req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=localhost',
            '-keyout', 'server.key', '-out', 'server.csr')
    for serial, (name, issuer, host) in enumerate([
        ('valid', 'trusted', 'localhost'), ('wrong-host', 'trusted', 'wrong.invalid'),
        ('untrusted-leaf', 'untrusted', 'localhost'), ('expired', 'trusted', 'localhost'),
    ], 2):
        (tmp / 'leaf.ext').write_text(f'subjectAltName=DNS:{host}\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n')
        if name == 'expired':
            (tmp / 'index').write_text('')
            (tmp / 'serial').write_text('05\n')
            (tmp / 'ca.cnf').write_text(
                '[ca]\ndefault_ca=test\n[test]\ndatabase=index\nserial=serial\n'
                'new_certs_dir=.\ndefault_md=sha256\npolicy=policy\n[policy]\ncommonName=supplied\n')
            openssl('ca', '-batch', '-config', 'ca.cnf', '-cert', 'trusted.pem',
                    '-keyfile', 'trusted.key', '-in', 'server.csr', '-out', 'expired.pem',
                    '-startdate', '20000101000000Z', '-enddate', '20010101000000Z',
                    '-extfile', 'leaf.ext')
        else:
            openssl('x509', '-req', '-in', 'server.csr', '-CA', f'{issuer}.pem',
                    '-CAkey', f'{issuer}.key', '-set_serial', str(serial), '-days', '1',
                    '-extfile', 'leaf.ext', '-out', f'{name}.pem')
    fixture_ca.write_bytes((tmp / 'trusted.pem').read_bytes())
    (tmp / '.curlrc').write_text('insecure\n')
    environment = dict(os.environ, CURL_HOME=str(tmp), XDG_CONFIG_HOME=str(tmp),
                       NO_PROXY='localhost,127.0.0.1', no_proxy='localhost,127.0.0.1')

    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().plugin_root = str(PLUGIN)
    lua.globals().fixture_plugin = str(fixture_plugin) + '/'
    lua.globals().decode = lambda value: lua.table_from(json.loads(value))

    def curl(command):
        assert command.startswith('/usr/bin/curl -q ') and ' --cacert ' in command
        result = subprocess.run(command, shell=True, env=environment, capture_output=True, check=True)
        return result.stdout.decode()

    lua.globals().curl = curl
    lua.execute('''
package.path=plugin_root.."/?.lua;"..package.path
package.loaded["json"]={decode=decode}
package.loaded["datastorage"]={}
package.loaded["device"]={isKindle=function() return true end}
package.loaded["infra/sui_paths"]={getPluginDir=function() return fixture_plugin end}
package.loaded["socket"]={dns={getaddrinfo=function() return {} end}}
io.popen=function(command)
 local output=curl(command)
 return {read=function() local data=output;output=nil;return data end,close=function() return true end}
end
News=require("features/sui_news")
''')

    def request(url):
        lua.globals().News.ORIGIN = url
        return lua.eval('News.request')('/api/entries')

    for name in ['valid', 'wrong-host', 'untrusted-leaf', 'expired']:
        with https_server(tmp / f'{name}.pem', tmp / 'server.key') as url:
            result = request(url)
        if name == 'valid':
            assert result['entries'] is not None
        else:
            assert result[0] is None and 'curl 60:' in result[1], (name, result)

    with https_server(tmp / 'valid.pem', tmp / 'server.key') as url:
        for contents in [None, b'', b'not a certificate']:
            if contents is None:
                fixture_ca.unlink()
            else:
                fixture_ca.write_bytes(contents)
            result = request(url)
            assert result[0] is None and 'curl 77:' in result[1], result
            assert 'reinstall the complete plugin' in result[1]

subprocess.run([sys.executable, str(ROOT / 'scripts/package.py')], check=True)
with zipfile.ZipFile(ROOT / 'dist/simpleui.koplugin.zip') as archive:
    for name in ['cacert.pem', 'bundle.json', 'README.md', 'LICENSE-MPL-2.0.txt']:
        assert archive.read('simpleui.koplugin/data/ca/' + name) == (CA / name).read_bytes()
print('PASS: pinned CA and package, real TLS verification, invalid CA failures, and curlrc isolation.')
