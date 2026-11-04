"""AWS Signature Version 4 for S3-compatible stores (Cloudflare R2), standard library only.
Shared by Scripts/fetch_data and Scripts/upload_data. Nothing here prints a secret or a signed header:
errors are scrubbed of the key id, the secret and the endpoint host before they leave this module."""
import datetime, hashlib, hmac, os, urllib.error, urllib.parse, urllib.request

UNSIGNED = 'UNSIGNED-PAYLOAD'

class DataError(Exception):
    """A failed request, with a message that is safe to print. `status` is the HTTP status when there was one."""
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status

def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

def asset_name(region, rel):
    """Name of a region file in the store: <region>--<path with / replaced by __>."""
    return f"{region}--{rel.replace('/', '__')}"

def credentials():
    """(key id, secret) from PEOPLEMAPS_DATA_KEY_ID and PEOPLEMAPS_DATA_SECRET, or None when neither is set.
    Empty counts as unset: GitHub passes an unset repository secret as an empty string."""
    kid, secret = os.environ.get('PEOPLEMAPS_DATA_KEY_ID', ''), os.environ.get('PEOPLEMAPS_DATA_SECRET', '')
    if not kid and not secret: return None
    if not kid or not secret: raise DataError('set both PEOPLEMAPS_DATA_KEY_ID and PEOPLEMAPS_DATA_SECRET, or neither')
    return kid, secret

def _hmac(key, msg): return hmac.new(key, msg.encode(), hashlib.sha256).digest()

def sign(method, url, key_id, secret, headers=None, payload_hash=UNSIGNED, now=None, region='auto', service='s3'):
    """Headers to send for `method url`, signed: the given headers plus x-amz-date,
    x-amz-content-sha256 and Authorization (host is signed but not returned; the HTTP client adds it). Every header passed in is signed too. `now` is a datetime (UTC), for tests."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    amz_date, day = now.strftime('%Y%m%dT%H%M%SZ'), now.strftime('%Y%m%d')
    u = urllib.parse.urlsplit(url)
    out = dict(headers or {})
    out['x-amz-date'] = amz_date
    out['x-amz-content-sha256'] = payload_hash
    signed = {k.lower(): ' '.join(str(v).split()) for k, v in out.items()}
    signed['host'] = u.netloc
    names = sorted(signed)
    path = urllib.parse.quote(urllib.parse.unquote(u.path) or '/', safe='/')  # S3 encodes the path once
    query = '&'.join(f'{k}={v}' for k, v in sorted(
        (urllib.parse.quote(k, safe=''), urllib.parse.quote(v, safe='')) for k, v in urllib.parse.parse_qsl(u.query, keep_blank_values=True)))
    canonical = '\n'.join([method, path, query, ''.join(f'{n}:{signed[n]}\n' for n in names), ';'.join(names), payload_hash])
    scope = f'{day}/{region}/{service}/aws4_request'
    to_sign = '\n'.join(['AWS4-HMAC-SHA256', amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    k = _hmac(_hmac(_hmac(_hmac(('AWS4' + secret).encode(), day), region), service), 'aws4_request')
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    out['Authorization'] = f'AWS4-HMAC-SHA256 Credential={key_id}/{scope}, SignedHeaders={";".join(names)}, Signature={sig}'
    return out

def scrub(text, *hidden):
    """`text` with every non-empty string in `hidden` replaced by ***."""
    for h in hidden:
        if h: text = text.replace(h, '***')
    return text

def request(method, url, creds=None, data=None, headers=None, timeout=120):
    """Open `url`, signed when `creds` is (key id, secret). Returns the response (a context manager).
    Raises DataError carrying only the status or reason, never the URL, key, secret or signature."""
    headers = dict(headers or {})
    if creds:
        headers = sign(method, url, creds[0], creds[1], headers)
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    hidden = [creds[0], creds[1], urllib.parse.urlsplit(url).netloc] if creds else []
    try:
        return urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.HTTPError as e:
        raise DataError(f'HTTP {e.code} {scrub(str(e.reason), *hidden)}', e.code) from None
    except (urllib.error.URLError, OSError) as e:
        raise DataError(scrub(str(getattr(e, 'reason', e)), *hidden) or type(e).__name__) from None
