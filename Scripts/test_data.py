"""Tests for the region data tools: the SigV4 signer (s3sig.py), Scripts/fetch_data and Scripts/upload_data.
No network: signing is checked against AWS's published examples, transfers run against file:// folders and a local HTTP server."""
import contextlib, datetime, hashlib, importlib.machinery, importlib.util, io, json, os, pathlib, sys, tempfile, threading, unittest
import http.server
from unittest import mock
import s3sig

HERE = pathlib.Path(__file__).resolve().parent

def load(name):
    loader = importlib.machinery.SourceFileLoader(name, str(HERE / name))
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
    return mod

fetch_data, upload_data = load('fetch_data'), load('upload_data')

KEY_ID, SECRET = 'AKIAIOSFODNN7EXAMPLE', 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'  # AWS's documentation credentials
ENV = ('PEOPLEMAPS_DATA_URL', 'PEOPLEMAPS_DATA_KEY_ID', 'PEOPLEMAPS_DATA_SECRET')

def env(**kw):
    """The data variables set to kw (others removed) for the duration of a `with`."""
    e = {k: v for k, v in os.environ.items() if k not in ENV}
    e.update(kw)
    return mock.patch.dict(os.environ, e, clear=True)

def sha(b): return hashlib.sha256(b).hexdigest()

class SigV4Tests(unittest.TestCase):
    """The examples in AWS's S3 documentation, "Authenticating Requests: Using the Authorization Header (AWS Signature Version 4)"."""
    NOW = datetime.datetime(2013, 5, 24, tzinfo=datetime.timezone.utc)
    EMPTY = sha(b'')
    HOST = 'https://examplebucket.s3.amazonaws.com'

    def signature(self, method, path, headers, payload=None):
        h = s3sig.sign(method, self.HOST + path, KEY_ID, SECRET, headers, payload or self.EMPTY, self.NOW, 'us-east-1')
        auth = h['Authorization']
        self.assertTrue(auth.startswith(f'AWS4-HMAC-SHA256 Credential={KEY_ID}/20130524/us-east-1/s3/aws4_request, SignedHeaders='))
        return auth.rsplit('Signature=', 1)[1]

    def test_get_object_with_range(self):
        self.assertEqual(self.signature('GET', '/test.txt', {'Range': 'bytes=0-9'}),
                         'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41')

    def test_put_object_encodes_the_path_and_signs_extra_headers(self):
        h = {'Date': 'Fri, 24 May 2013 00:00:00 GMT', 'x-amz-storage-class': 'REDUCED_REDUNDANCY'}
        self.assertEqual(self.signature('PUT', '/test%24file.text', h, sha(b'Welcome to Amazon S3.')),
                         '98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd')

    def test_get_bucket_lifecycle(self):
        self.assertEqual(self.signature('GET', '/?lifecycle', {}),
                         'fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543')

    def test_list_objects_sorts_the_query(self):
        self.assertEqual(self.signature('GET', '/?prefix=J&max-keys=2', {}),
                         '34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7')

    def test_returns_the_headers_to_send(self):
        h = s3sig.sign('GET', self.HOST + '/x', KEY_ID, SECRET, {}, now=self.NOW)
        self.assertEqual(h['x-amz-date'], '20130524T000000Z')
        self.assertEqual({k.lower(): v for k, v in h.items()}['x-amz-content-sha256'], 'UNSIGNED-PAYLOAD')
        self.assertIn('Credential=%s/20130524/auto/s3/aws4_request' % KEY_ID, h['Authorization'])
        self.assertIn('SignedHeaders=host;x-amz-content-sha256;x-amz-date,', h['Authorization'])

    def test_credentials_from_the_environment(self):
        with env(): self.assertIsNone(s3sig.credentials())
        with env(PEOPLEMAPS_DATA_KEY_ID='', PEOPLEMAPS_DATA_SECRET=''): self.assertIsNone(s3sig.credentials())  # CI on a fork
        with env(PEOPLEMAPS_DATA_KEY_ID='a', PEOPLEMAPS_DATA_SECRET='b'): self.assertEqual(s3sig.credentials(), ('a', 'b'))
        with env(PEOPLEMAPS_DATA_KEY_ID='a'):
            with self.assertRaises(s3sig.DataError): s3sig.credentials()

class Store(http.server.BaseHTTPRequestHandler):
    """A tiny S3 stand-in: keeps PUT bodies by path, answers HEAD and GET, records every request. It does not check signatures."""
    objects, log = {}, []
    def log_message(self, *a): pass
    def _record(self): self.log.append((self.command, self.path, dict(self.headers)))
    def do_PUT(self):
        self._record()
        self.objects[self.path] = self.rfile.read(int(self.headers['Content-Length']))
        self.send_response(200); self.send_header('Content-Length', '0'); self.end_headers()
    def _get(self, body):
        self._record()
        data = self.objects.get(self.path)
        if data is None:
            self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers(); return
        self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers()
        if body: self.wfile.write(data)
    def do_GET(self): self._get(True)
    def do_HEAD(self): self._get(False)

class Server(http.server.ThreadingHTTPServer):
    def server_bind(self):  # the stock one calls socket.getfqdn, a reverse DNS lookup that can take 30 s
        self.socket.bind(self.server_address)
        self.server_address = self.socket.getsockname()
        self.server_name, self.server_port = 'localhost', self.server_address[1]

class DataToolTests(unittest.TestCase):
    FILES = {'expected/a.bin': b'alpha' * 100, 'b.json.gz': b'beta'}

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(); self.addCleanup(self._tmp.cleanup)
        self.tmp = pathlib.Path(self._tmp.name)
        self.dest = self.tmp / 'region'
        self.manifest = self.tmp / 'regions.json'
        self.write_manifest()

    def write_manifest(self, tamper=None):
        files = {rel: {'bytes': len(b), 'sha256': sha(b)} for rel, b in self.FILES.items()}
        if tamper: files[tamper]['sha256'] = '0' * 64
        self.manifest.write_text(json.dumps({'release': 'data-test-1', 'regions': {'r': {'files': files}}}))

    def mirror(self, prefix=''):
        """A directory laid out as fetch_data expects, returning its file:// URL."""
        d = self.tmp / 'mirror'
        (d / prefix).mkdir(parents=True, exist_ok=True)
        for rel, b in self.FILES.items(): (d / prefix / s3sig.asset_name('r', rel)).write_bytes(b)
        return d.as_uri()

    def run_tool(self, tool, *args, **kw):
        """(exit message or None, printed output) of tool.main."""
        out, msg = io.StringIO(), None
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            try: tool.main(list(args), **kw)
            except SystemExit as e: msg = str(e.code)
        return msg, out.getvalue()

    def serve(self):
        Store.objects, Store.log = {}, []
        srv = Server(('127.0.0.1', 0), Store)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close); self.addCleanup(srv.shutdown)
        return f'http://127.0.0.1:{srv.server_address[1]}/peoplemaps-data'

    # fetch_data, plain
    def test_file_url_fetches_and_verifies(self):
        with env(PEOPLEMAPS_DATA_URL=self.mirror()):
            msg, out = self.run_tool(fetch_data, manifest=self.manifest, dest=self.dest)
        self.assertIsNone(msg)
        for rel, b in self.FILES.items(): self.assertEqual((self.dest / 'r' / rel).read_bytes(), b)
        self.assertEqual(out.count('fetching'), 2)
        self.assertEqual((self.dest / 'r/b.json.gz').stat().st_mode & 0o777, 0o644)

    def test_present_files_are_left_alone_quietly(self):
        with env(PEOPLEMAPS_DATA_URL=self.mirror()):
            self.run_tool(fetch_data, manifest=self.manifest, dest=self.dest)
            msg, out = self.run_tool(fetch_data, manifest=self.manifest, dest=self.dest)
        self.assertEqual((msg, out), (None, ''))

    def test_wrong_sha256_fails_and_leaves_nothing(self):
        self.write_manifest(tamper='b.json.gz')
        with env(PEOPLEMAPS_DATA_URL=self.mirror()):
            msg, _ = self.run_tool(fetch_data, manifest=self.manifest, dest=self.dest)
        self.assertIn('does not match the pin', msg)
        self.assertFalse((self.dest / 'r/b.json.gz').exists())
        self.assertEqual(list((self.dest / 'r').glob('*.part')), [])

    def test_unknown_region(self):
        with env(PEOPLEMAPS_DATA_URL=self.mirror()):
            msg, _ = self.run_tool(fetch_data, 'nope', manifest=self.manifest, dest=self.dest)
        self.assertIn('no region "nope"', msg)

    def test_unset_or_empty_url_exits_with_the_variables_needed(self):
        # Unset, and a fork's CI run where the secrets exist but are empty.
        for e in ({}, dict(PEOPLEMAPS_DATA_URL='', PEOPLEMAPS_DATA_KEY_ID='', PEOPLEMAPS_DATA_SECRET='')):
            with env(**e), mock.patch.object(s3sig, 'request', side_effect=AssertionError('no request expected')):
                msg, _ = self.run_tool(fetch_data, 'r', manifest=self.manifest, dest=self.dest)
            self.assertIn('PEOPLEMAPS_DATA_URL, PEOPLEMAPS_DATA_KEY_ID and PEOPLEMAPS_DATA_SECRET are needed', msg)
            self.assertIn('Docs/ARCHITECTURE.md', msg)

    def test_credentials_without_a_url_are_refused(self):
        msg, _ = self.run_tool_env(fetch_data, PEOPLEMAPS_DATA_KEY_ID='k', PEOPLEMAPS_DATA_SECRET='s')
        self.assertIn('PEOPLEMAPS_DATA_URL', msg)

    def run_tool_env(self, tool, *args, **e):
        with env(**e): return self.run_tool(tool, *args, manifest=self.manifest, **({'dest': self.dest} if tool is fetch_data else {'src': self.dest}))

    # fetch_data and upload_data, signed
    def test_signed_fetch_uses_the_release_as_key_prefix(self):
        base = self.serve()
        for rel, b in self.FILES.items(): Store.objects[f'/peoplemaps-data/data-test-1/{s3sig.asset_name("r", rel)}'] = b
        msg, _ = self.run_tool_env(fetch_data, PEOPLEMAPS_DATA_URL=base, PEOPLEMAPS_DATA_KEY_ID=KEY_ID, PEOPLEMAPS_DATA_SECRET=SECRET)
        self.assertIsNone(msg)
        for rel, b in self.FILES.items(): self.assertEqual((self.dest / 'r' / rel).read_bytes(), b)
        self.assertEqual({m for m, _, _ in Store.log}, {'GET'})
        for _, _, h in Store.log:
            self.assertTrue(h['Authorization'].startswith(f'AWS4-HMAC-SHA256 Credential={KEY_ID}/'))
            self.assertEqual({k.lower(): v for k, v in h.items()}['x-amz-content-sha256'], 'UNSIGNED-PAYLOAD')

    def test_upload_puts_each_file_then_skips_when_sizes_match(self):
        base = self.serve()
        for rel, b in self.FILES.items():
            p = self.dest / 'r' / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(b)
        creds = dict(PEOPLEMAPS_DATA_URL=base, PEOPLEMAPS_DATA_KEY_ID=KEY_ID, PEOPLEMAPS_DATA_SECRET=SECRET)
        msg, out = self.run_tool_env(upload_data, **creds)
        self.assertIsNone(msg)
        self.assertEqual(out.count('upload data-test-1/r--'), 2)
        for rel, b in self.FILES.items(): self.assertEqual(Store.objects[f'/peoplemaps-data/data-test-1/{s3sig.asset_name("r", rel)}'], b)
        puts = [m for m, _, _ in Store.log if m == 'PUT']
        msg, out = self.run_tool_env(upload_data, **creds)
        self.assertIsNone(msg)
        self.assertEqual(out.count('skip   data-test-1/r--'), 2)
        self.assertEqual([m for m, _, _ in Store.log if m == 'PUT'], puts)  # no new PUTs

    def test_upload_checks_sha256_before_sending_anything(self):
        base = self.serve()
        for rel, b in self.FILES.items():
            p = self.dest / 'r' / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(b)
        (self.dest / 'r/b.json.gz').write_bytes(b'tampered')
        msg, _ = self.run_tool_env(upload_data, PEOPLEMAPS_DATA_URL=base, PEOPLEMAPS_DATA_KEY_ID=KEY_ID, PEOPLEMAPS_DATA_SECRET=SECRET)
        self.assertIn('does not match the manifest', msg)
        self.assertEqual(Store.log, [])

    def test_upload_needs_all_three_variables(self):
        msg, _ = self.run_tool_env(upload_data, PEOPLEMAPS_DATA_KEY_ID=KEY_ID, PEOPLEMAPS_DATA_SECRET=SECRET)
        self.assertIn('PEOPLEMAPS_DATA_URL', msg)

    # secrets stay out of errors
    def assert_no_secrets(self, text, *extra):
        for hidden in (KEY_ID, SECRET, 'Signature=', 'AWS4-HMAC', *extra): self.assertNotIn(hidden, text)

    def test_failed_signed_fetch_prints_no_secret(self):
        secret = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY-unique'
        host = 'peoplemaps-unreachable-account.invalid'
        msg, out = self.run_tool_env(fetch_data, PEOPLEMAPS_DATA_URL=f'https://{host}/peoplemaps-data',
                                     PEOPLEMAPS_DATA_KEY_ID=KEY_ID, PEOPLEMAPS_DATA_SECRET=secret)
        self.assertTrue(msg)
        self.assert_no_secrets(msg + out, secret, host)

    def test_signed_http_error_prints_no_secret(self):
        base = self.serve()  # nothing stored: 404
        msg, out = self.run_tool_env(fetch_data, PEOPLEMAPS_DATA_URL=base, PEOPLEMAPS_DATA_KEY_ID=KEY_ID, PEOPLEMAPS_DATA_SECRET=SECRET)
        self.assertIn('HTTP 404', msg)
        self.assert_no_secrets(msg + out, '127.0.0.1')

    def test_scrub_removes_everything_it_is_given(self):
        self.assertEqual(s3sig.scrub('a SECRET b KEY c', 'SECRET', 'KEY', ''), 'a *** b *** c')

if __name__ == '__main__': unittest.main()
