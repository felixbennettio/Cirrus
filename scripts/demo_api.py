#!/usr/bin/env python3
"""A stand-in for the Cloudflare API with made-up demo data, for screenshots.

    python3 scripts/demo_api.py [--port 8787] [--lang en|zh]

Build the app against it with
`--dart-define=CIRRUS_API_BASE=http://127.0.0.1:8787/client/v4` and add a
profile with any token, or write one to profiles.json in the app's support
directory before the first start (.github/workflows/screenshots.yml does).
Such builds open the page in CIRRUS_INITIAL_ROUTE. Writes are accepted and
echoed but change nothing. Every name, address and number here is invented;
domains use the reserved example names.
"""
import argparse
import json
import math
import random
import re
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

LANG = 'en'
NOW = datetime.now(timezone.utc).replace(microsecond=0)


def t(en, zh):
    return zh if LANG == 'zh' else en


def ago(**kw):
    return (NOW - timedelta(**kw)).isoformat().replace('+00:00', 'Z')


def ahead(**kw):
    return (NOW + timedelta(**kw)).isoformat().replace('+00:00', 'Z')


def hexid(seed, n=32):
    rng = random.Random(seed)
    return ''.join(rng.choice('0123456789abcdef') for _ in range(n))


# ---------------------------------------------------------------------------
# Accounts, user, zones

ACC = hexid('account')
ACC2 = hexid('account2')


def accounts():
    return [
        {'id': ACC, 'name': t('Acme Studio', 'Acme 工作室'), 'type': 'standard', 'created_on': ago(days=900),
         'settings': {'enforce_twofactor': True}},
        {'id': ACC2, 'name': t('Personal', '个人账户'), 'type': 'standard', 'created_on': ago(days=1500), 'settings': {}},
    ]


USER = {
    'id': hexid('user'), 'email': 'alex@example.com', 'first_name': 'Alex', 'last_name': 'Chen',
    'username': 'alexchen', 'telephone': None, 'country': 'SG', 'two_factor_authentication_enabled': True,
    'suspended': False, 'created_on': ago(days=1500), 'modified_on': ago(days=20),
}

PLANS = {
    'free': {'id': hexid('plan-free'), 'name': 'Free Website', 'price': 0, 'currency': 'USD', 'frequency': '',
             'is_subscribed': True, 'can_subscribe': False, 'legacy_id': 'free', 'legacy_discount': False,
             'externally_managed': False},
    'pro': {'id': hexid('plan-pro'), 'name': 'Pro Website', 'price': 20, 'currency': 'USD', 'frequency': 'monthly',
            'is_subscribed': True, 'can_subscribe': True, 'legacy_id': 'pro', 'legacy_discount': False,
            'externally_managed': False},
    'business': {'id': hexid('plan-biz'), 'name': 'Business Website', 'price': 200, 'currency': 'USD',
                 'frequency': 'monthly', 'is_subscribed': True, 'can_subscribe': True, 'legacy_id': 'business',
                 'legacy_discount': False, 'externally_managed': False},
}


def zone(name, plan='free', status='active', paused=False, days=400, account=ACC):
    zid = hexid('zone-' + name)
    return {
        'id': zid, 'name': name, 'status': status, 'paused': paused, 'type': 'full', 'development_mode': 0,
        'name_servers': ['ada.ns.cloudflare.com', 'kip.ns.cloudflare.com'],
        'original_name_servers': ['ns1.registrar.example', 'ns2.registrar.example'],
        'original_registrar': 'example registrar', 'original_dnshost': None,
        'created_on': ago(days=days), 'modified_on': ago(days=3),
        'activated_on': None if status == 'pending' else ago(days=days - 1),
        'account': {'id': account, 'name': next(a['name'] for a in accounts() if a['id'] == account)},
        'owner': {'id': USER['id'], 'type': 'user', 'email': USER['email']},
        'permissions': ['#zone:read', '#zone:edit', '#dns_records:edit'],
        'plan': PLANS[plan], 'meta': {'step': 4, 'phishing_detected': False},
        'vanity_name_servers': [], 'verification_key': None,
    }


ZONES = [
    zone('example.com', 'pro', days=820),
    zone('example.net', 'business', days=610),
    zone('example.org', days=450),
    zone('shop.example', days=200),
    zone('docs.example', days=120),
    zone('status.example', days=60, paused=True),
    zone('new-project.example', status='pending', days=2),
    zone('alexchen.example', days=1400, account=ACC2),
]


def zone_by_id(zid):
    return next((z for z in ZONES if z['id'] == zid), ZONES[0])


# ---------------------------------------------------------------------------
# DNS

def dns_records(z):
    n = z['name']

    def rec(i, type_, name, content, proxied=False, ttl=1, comment=None, tags=(), priority=None, days=200):
        r = {'id': hexid(f'{n}-dns-{i}'), 'zone_id': z['id'], 'zone_name': n, 'name': name, 'type': type_,
             'content': content, 'proxiable': type_ in ('A', 'AAAA', 'CNAME'), 'proxied': proxied, 'ttl': ttl,
             'comment': comment, 'tags': list(tags), 'settings': {}, 'meta': {},
             'created_on': ago(days=days), 'modified_on': ago(days=days // 3)}
        if priority is not None:
            r['priority'] = priority
        return r

    return [
        rec(1, 'A', n, '203.0.113.10', True, comment=t('Main web server', '主站服务器'), tags=['env:prod']),
        rec(2, 'AAAA', n, '2001:db8::10', True),
        rec(3, 'CNAME', 'www.' + n, n, True),
        rec(4, 'A', 'api.' + n, '198.51.100.24', True, comment=t('API cluster, Singapore', 'API 集群（新加坡）'),
            tags=['env:prod', 'team:backend']),
        rec(5, 'CNAME', 'blog.' + n, 'acme-blog.pages.dev', True),
        rec(6, 'CNAME', 'shop.' + n, 'shops.example.net', True, comment=t('Storefront', '商店前台')),
        rec(7, 'A', 'staging.' + n, '198.51.100.77', False, 300, t('Staging, not proxied', '预发布环境，未代理'),
            ['env:staging']),
        rec(8, 'CNAME', 'status.' + n, 'status.example', False, 3600),
        rec(9, 'MX', n, 'route1.mx.cloudflare.net', ttl=1, priority=12),
        rec(10, 'MX', n, 'route2.mx.cloudflare.net', ttl=1, priority=50),
        rec(11, 'TXT', n, '"v=spf1 include:_spf.mx.cloudflare.net ~all"'),
        rec(12, 'TXT', '_dmarc.' + n, '"v=DMARC1; p=quarantine; rua=mailto:dmarc@' + n + '"'),
        rec(13, 'CAA', n, '0 issue "letsencrypt.org"'),
        rec(14, 'SRV', '_sip._tcp.' + n, '10 60 5060 sip.' + n, priority=10),
        rec(15, 'TXT', 'cf2024-1._domainkey.' + n, '"v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAo"'),
        rec(16, 'A', 'vpn.' + n, '192.0.2.44', False, 120, t('Office VPN', '办公室 VPN')),
        rec(17, 'CNAME', 'cdn.' + n, 'assets.example.org', True),
        rec(18, 'AAAA', 'api.' + n, '2001:db8::24', True),
    ]


# ---------------------------------------------------------------------------
# Zone settings

def zone_settings():
    s = {
        'ssl': 'strict', 'always_use_https': 'on', 'min_tls_version': '1.2', 'tls_1_3': 'zrt',
        'automatic_https_rewrites': 'on', 'opportunistic_encryption': 'on', 'security_level': 'medium',
        'development_mode': 'off', 'browser_check': 'on', 'challenge_ttl': 1800, 'brotli': 'on', 'early_hints': 'on',
        'http2': 'on', 'http3': 'on', '0rtt': 'on', 'ipv6': 'on', 'websockets': 'on', 'always_online': 'on',
        'cache_level': 'aggressive', 'browser_cache_ttl': 14400, 'rocket_loader': 'off', 'email_obfuscation': 'on',
        'hotlink_protection': 'off', 'ip_geolocation': 'on', 'server_side_exclude': 'on', 'pseudo_ipv4': 'off',
        'privacy_pass': 'on', 'tls_client_auth': 'off', 'true_client_ip_header': 'off', 'waf': 'on',
        'polish': 'lossless', 'webp': 'on', 'mirage': 'off', 'image_resizing': 'on', 'speed_brain': 'on',
        'origin_max_http_version': '2', 'sort_query_string_for_cache': 'off', 'cname_flattening': 'flatten_at_root',
        'max_upload': 100, 'response_buffering': 'off', 'prefetch_preload': 'off', 'automatic_platform_optimization':
            {'enabled': False, 'cf': False, 'wordpress': False, 'wp_plugin': False, 'hostnames': [], 'cache_by_device_type': False},
        'security_header': {'strict_transport_security': {'enabled': True, 'max_age': 31536000,
                                                          'include_subdomains': True, 'preload': True, 'nosniff': True}},
        'minify': {'css': 'off', 'html': 'off', 'js': 'off'},
        'ciphers': [], 'nel': {'enabled': False}, 'replace_insecure_js': 'on', 'filter_logs_to_cloudflare': 'off',
    }
    return [{'id': k, 'value': v, 'editable': True, 'modified_on': ago(days=12)} for k, v in s.items()]


def setting(name):
    for s in zone_settings():
        if s['id'] == name:
            return s
    return {'id': name, 'value': 'on', 'editable': True, 'modified_on': ago(days=12)}


# ---------------------------------------------------------------------------
# Analytics (GraphQL)

def wave(i, n, base, amp, seed):
    r = random.Random(seed * 1000 + i)
    day = math.sin((i / n) * math.pi * 2 * (n / 24 if n > 31 else 1) - 1.2)
    return max(0.0, base * (1 + amp * day) * (0.85 + 0.3 * r.random()))


STATUS = [(200, 0.86), (304, 0.06), (301, 0.025), (404, 0.03), (403, 0.012), (500, 0.003), (502, 0.002)]
COUNTRIES = [('US', 0.27), ('CN', 0.18), ('JP', 0.1), ('DE', 0.08), ('SG', 0.07), ('GB', 0.06), ('FR', 0.05),
             ('IN', 0.05), ('BR', 0.04), ('CA', 0.04), ('RU', 0.03), ('AU', 0.03)]


def traffic_group(i, n, hourly, when, seed):
    base = 52000 if hourly else 1250000
    req = wave(i, n, base, 0.45, seed)
    cached = req * (0.62 + 0.1 * random.Random(seed + i).random())
    bytes_ = req * 48000
    return {
        'dimensions': {'datetime' if hourly else 'date': when},
        'sum': {
            'requests': int(req), 'cachedRequests': int(cached), 'bytes': int(bytes_),
            'cachedBytes': int(bytes_ * 0.71), 'threats': int(req * 0.004), 'pageViews': int(req * 0.31),
            'responseStatusMap': [{'edgeResponseStatus': c, 'requests': int(req * f)} for c, f in STATUS],
            'countryMap': [{'clientCountryName': c, 'requests': int(req * f)} for c, f in COUNTRIES],
        },
        'uniq': {'uniques': int(req * 0.09)},
    }


def graphql(body):
    q = body.get('query', '')
    v = body.get('variables') or {}
    seed = 7
    if 'httpRequests1hGroups' in q:
        until = datetime.fromisoformat(str(v.get('until', NOW.isoformat())).replace('Z', '+00:00'))
        since = datetime.fromisoformat(str(v.get('since', (NOW - timedelta(hours=24)).isoformat())).replace('Z', '+00:00'))
        n = max(1, int((until - since).total_seconds() // 3600))
        groups = [traffic_group(i, n, True, (since + timedelta(hours=i)).isoformat().replace('+00:00', 'Z'), seed)
                  for i in range(n)]
        return {'viewer': {'zones': [{'httpRequests1hGroups': groups}]}}
    if 'httpRequests1dGroups' in q:
        since = datetime.strptime(str(v.get('since', (NOW - timedelta(days=6)).strftime('%Y-%m-%d'))), '%Y-%m-%d')
        until = datetime.strptime(str(v.get('until', NOW.strftime('%Y-%m-%d'))), '%Y-%m-%d')
        n = (until - since).days + 1
        groups = [traffic_group(i, n, False, (since + timedelta(days=i)).strftime('%Y-%m-%d'), seed) for i in range(n)]
        return {'viewer': {'zones': [{'httpRequests1dGroups': groups}]}}
    if 'workersInvocationsAdaptive' in q:
        rows = []
        for h in range(24):
            when = (NOW - timedelta(hours=23 - h)).replace(minute=0, second=0).isoformat().replace('+00:00', 'Z')
            for script, base in (('api-gateway', 42000), ('image-resizer', 15000), ('auth-edge', 9000),
                                 ('og-image', 2600), ('cron-cleanup', 4)):
                req = int(wave(h, 24, base, 0.5, len(script)))
                rows.append({'dimensions': {'scriptName': script, 'datetimeHour': when},
                             'sum': {'requests': req, 'errors': int(req * 0.002), 'subrequests': int(req * 1.4)},
                             'quantiles': {'cpuTimeP50': 1.8 + len(script) % 3, 'cpuTimeP99': 9.5 + len(script)}})
        return {'viewer': {'accounts': [{'workersInvocationsAdaptive': rows}]}}
    if 'firewallEventsAdaptive' in q:
        rng = random.Random(3)
        acts = ['block', 'managed_challenge', 'block', 'log', 'jschallenge', 'skip']
        srcs = ['firewallManaged', 'firewallCustom', 'ratelimit', 'bic', 'securitylevel']
        paths = ['/wp-login.php', '/api/v1/login', '/.env', '/admin', '/xmlrpc.php', '/api/v1/orders', '/search']
        ccs = ['US', 'CN', 'RU', 'DE', 'BR', 'IN', 'NL', 'VN']
        ev = []
        for i in range(40):
            ev.append({'action': rng.choice(acts), 'source': rng.choice(srcs), 'clientIP': f'198.51.100.{rng.randint(2, 250)}',
                       'clientCountryName': rng.choice(ccs), 'clientAsn': str(rng.choice([13335, 4134, 16509, 14061, 45102])),
                       'clientRequestHTTPHost': 'example.com', 'clientRequestHTTPMethodName': rng.choice(['GET', 'POST']),
                       'clientRequestPath': rng.choice(paths), 'datetime': ago(minutes=i * 17 + rng.randint(0, 10)),
                       'rayName': hexid(f'ray{i}', 16)})
        return {'viewer': {'zones': [{'firewallEventsAdaptive': ev}]}}
    return {'viewer': {'zones': [], 'accounts': []}}


# ---------------------------------------------------------------------------
# Workers, Pages

SCRIPTS = [
    ('api-gateway', ['fetch'], 2), ('image-resizer', ['fetch'], 9), ('auth-edge', ['fetch'], 15),
    ('og-image', ['fetch'], 30), ('cron-cleanup', ['scheduled'], 41), ('webhook-relay', ['fetch', 'queue'], 64),
]


def scripts():
    return [{'id': n, 'tag': hexid('tag' + n), 'handlers': h, 'created_on': ago(days=d * 6), 'modified_on': ago(days=d, hours=3),
             'usage_model': 'standard', 'compatibility_date': '2026-09-01', 'compatibility_flags': ['nodejs_compat'],
             'etag': hexid('etag' + n), 'has_assets': n == 'og-image', 'has_modules': True, 'logpush': False,
             'placement_mode': 'smart' if n == 'api-gateway' else None, 'tail_consumers': None,
             'observability': {'enabled': True, 'head_sampling_rate': 1}} for n, h, d in SCRIPTS]


WORKER_SRC = '''import { Router } from './router.js';

const router = new Router();

router.get('/v1/health', () => Response.json({ ok: true }));

router.get('/v1/orders/:id', async (req, env) => {
  const order = await env.DB.prepare('SELECT * FROM orders WHERE id = ?')
    .bind(req.params.id)
    .first();
  if (!order) return new Response('Not found', { status: 404 });
  return Response.json(order);
});

router.post('/v1/orders', async (req, env) => {
  const body = await req.json();
  await env.QUEUE.send({ type: 'order.created', body });
  return Response.json({ queued: true }, { status: 202 });
});

export default {
  async fetch(request, env, ctx) {
    const cached = await caches.default.match(request);
    if (cached) return cached;
    return router.handle(request, env, ctx);
  },
};
'''


def worker_settings(name):
    return {
        'bindings': [
            {'type': 'd1', 'name': 'DB', 'id': hexid('d1-orders'), 'database_name': 'orders'},
            {'type': 'kv_namespace', 'name': 'SESSIONS', 'namespace_id': hexid('kv-sessions')},
            {'type': 'r2_bucket', 'name': 'ASSETS', 'bucket_name': 'acme-assets'},
            {'type': 'queue', 'name': 'QUEUE', 'queue_name': 'order-events'},
            {'type': 'plain_text', 'name': 'API_VERSION', 'text': '2026-10'},
            {'type': 'secret_text', 'name': 'JWT_SECRET'},
            {'type': 'ai', 'name': 'AI'},
        ],
        'compatibility_date': '2026-09-01', 'compatibility_flags': ['nodejs_compat'], 'logpush': False,
        'observability': {'enabled': True, 'head_sampling_rate': 1}, 'placement': {'mode': 'smart'},
        'tags': [], 'tail_consumers': [], 'usage_model': 'standard',
    }


def deployments(name):
    msgs = [t('Cache order lookups', '缓存订单查询'), t('Add rate limiting', '加入限流'),
            t('Move to smart placement', '启用智能放置'), t('Initial deploy', '首次部署')]
    out = []
    for i, m in enumerate(msgs):
        vid = hexid(f'{name}-v{i}')
        out.append({'id': hexid(f'{name}-dep{i}'), 'created_on': ago(days=i * 9 + 1, hours=i * 3),
                    'source': 'wrangler', 'author_email': 'alex@example.com', 'strategy': 'percentage',
                    'versions': [{'version_id': vid, 'percentage': 100.0}],
                    'annotations': {'workers/message': m, 'workers/triggered_by': 'deployment'}})
    return out


def versions(name):
    out = []
    for i in range(6):
        out.append({'id': hexid(f'{name}-v{i}'), 'number': 24 - i,
                    'metadata': {'created_on': ago(days=i * 6 + 1), 'modified_on': ago(days=i * 6 + 1),
                                 'source': 'wrangler' if i % 3 else 'dash', 'author_email': 'alex@example.com',
                                 'author_id': USER['id']},
                    'annotations': {'workers/message': t(f'Release {24 - i}', f'版本 {24 - i}'),
                                    'workers/triggered_by': 'upload'}})
    return out


def pages_projects():
    def proj(name, repo, days, branch_msg, domains, status='success', fw='astro'):
        return {
            'id': hexid('pages' + name), 'name': name, 'subdomain': name + '.pages.dev', 'domains': domains,
            'production_branch': 'main', 'created_on': ago(days=days * 20),
            'source': {'type': 'github', 'config': {'owner': 'acme', 'repo_name': repo, 'production_branch': 'main',
                                                    'pr_comments_enabled': True, 'deployments_enabled': True}},
            'build_config': {'build_command': 'npm run build', 'destination_dir': 'dist', 'root_dir': '',
                             'web_analytics_tag': None},
            'framework': fw,
            'latest_deployment': {
                'id': hexid('dep' + name), 'short_id': hexid('dep' + name, 8), 'project_name': name,
                'url': f'https://{hexid("dep" + name, 8)}.{name}.pages.dev', 'environment': 'production',
                'created_on': ago(hours=days * 5), 'modified_on': ago(hours=days * 5),
                'deployment_trigger': {'type': 'github:push',
                                       'metadata': {'branch': 'main', 'commit_hash': hexid('c' + name, 40),
                                                    'commit_message': branch_msg, 'commit_dirty': False}},
                'latest_stage': {'name': 'deploy', 'status': status, 'started_on': ago(hours=days * 5),
                                 'ended_on': ago(hours=days * 5)},
                'stages': [{'name': s, 'status': status, 'started_on': ago(hours=days * 5), 'ended_on': ago(hours=days * 5)}
                           for s in ('queued', 'initialize', 'clone_repo', 'build', 'deploy')],
                'aliases': None, 'production_branch': 'main',
            },
            'canonical_deployment': None,
            'deployment_configs': {'production': {'env_vars': {'NODE_VERSION': {'type': 'plain_text', 'value': '22'}},
                                                  'compatibility_date': '2026-09-01'},
                                   'preview': {'env_vars': {}, 'compatibility_date': '2026-09-01'}},
        }
    return [
        proj('acme-blog', 'blog', 1, t('Publish: Edge caching in practice', '发布：边缘缓存实践'), ['blog.example.com']),
        proj('acme-docs', 'docs', 3, t('Docs: new API reference', '文档：新的 API 参考'), ['docs.example']),
        proj('landing', 'landing', 7, t('Hero copy update', '更新首屏文案'), ['example.org', 'www.example.org']),
        proj('status-page', 'status', 15, t('Incident template', '故障公告模板'), [], 'failure'),
        proj('design-system', 'design', 30, t('Tokens v3', '设计令牌 v3'), [], fw='vite'),
    ]


def pages_deployments(name):
    msgs = [t('Publish: Edge caching in practice', '发布：边缘缓存实践'), t('Fix RSS dates', '修复 RSS 日期'),
            t('Add dark mode', '加入深色模式'), t('Preview: new layout', '预览：新布局'), t('Bump deps', '升级依赖')]
    out = []
    for i, m in enumerate(msgs):
        env = 'preview' if i == 3 else 'production'
        sid = hexid(f'{name}-pd{i}', 8)
        out.append({'id': hexid(f'{name}-pd{i}'), 'short_id': sid, 'project_name': name, 'environment': env,
                    'url': f'https://{sid}.{name}.pages.dev', 'created_on': ago(days=i * 2, hours=i),
                    'deployment_trigger': {'type': 'github:push', 'metadata': {
                        'branch': 'feature/layout' if env == 'preview' else 'main',
                        'commit_hash': hexid(f'{name}-c{i}', 40), 'commit_message': m}},
                    'latest_stage': {'name': 'deploy', 'status': 'failure' if i == 4 else 'success'},
                    'aliases': None})
    return out


# ---------------------------------------------------------------------------
# Storage

KV = [('SESSIONS', 'kv-sessions'), ('FEATURE_FLAGS', 'kv-flags'), ('RATE_LIMITS', 'kv-rl'),
      ('TRANSLATIONS', 'kv-i18n'), ('CACHE_META', 'kv-cache')]


def kv_namespaces():
    return [{'id': hexid(s), 'title': n, 'supports_url_encoding': True} for n, s in KV]


def kv_keys():
    keys = ['flags:checkout-v2', 'flags:dark-mode', 'flags:new-pricing', 'flags:search-beta', 'i18n:en', 'i18n:ja',
            'i18n:zh-Hans', 'session:8f3a1c', 'session:a91d07', 'session:c22e5b', 'user:1042:prefs', 'user:2088:prefs',
            'user:3121:prefs', 'config:regions', 'config:limits']
    out = []
    for i, k in enumerate(keys):
        e = {'name': k}
        if k.startswith('session:'):
            e['expiration'] = int((NOW + timedelta(hours=6 + i)).timestamp())
        if k.startswith('flags:'):
            e['metadata'] = {'owner': 'growth', 'rollout': 50 + i * 10}
        out.append(e)
    return out


BUCKETS = [('acme-assets', 'APAC', 60), ('backups', 'WEUR', 300), ('user-uploads', 'ENAM', 120),
           ('logs-archive', 'WNAM', 500)]


def r2_buckets():
    return {'buckets': [{'name': n, 'creation_date': ago(days=d), 'location': loc, 'storage_class': 'Standard',
                         'jurisdiction': 'default'} for n, loc, d in BUCKETS]}


def r2_objects(prefix):
    if prefix == '':
        objs = [('favicon.ico', 15086, 'image/x-icon'), ('robots.txt', 120, 'text/plain'),
                ('manifest.webmanifest', 812, 'application/manifest+json'), ('hero.webp', 284113, 'image/webp'),
                ('logo.svg', 4210, 'image/svg+xml'), ('fonts.css', 2934, 'text/css')]
        folders = ['css/', 'fonts/', 'images/', 'js/', 'video/']
    else:
        objs = [(prefix + f'photo-{i:03d}.webp', 120000 + i * 3133, 'image/webp') for i in range(1, 12)]
        folders = []
    return ([{'key': k, 'size': s, 'etag': hexid(k), 'last_modified': ago(days=len(k), hours=len(k) * 2),
              'http_metadata': {'contentType': c}, 'storage_class': 'Standard'} for k, s, c in objs], folders)


D1 = [('orders', 14, 48_234_496, 'production'), ('analytics', 6, 182_452_224, 'production'),
      ('auth', 5, 3_506_176, 'production'), ('staging-orders', 14, 1_253_376, 'production')]


def d1_databases():
    return [{'uuid': hexid('d1-' + n), 'name': n, 'version': v, 'created_at': ago(days=40 + i * 30),
             'num_tables': tables, 'file_size': size} for i, (n, tables, size, v) in enumerate(D1)]


def d1_query(sql):
    s = sql.lower()
    if 'sqlite_master' in s or 'sqlite_schema' in s:
        rows = [{'name': n, 'type': 'table', 'sql': f'CREATE TABLE {n} (...)'} for n in
                ('customers', 'orders', 'order_items', 'products', 'refunds', 'coupons')]
    else:
        rows = [{'id': 1000 + i, 'customer': f'customer{i}@example.com', 'total': round(19.9 + i * 7.35, 2),
                 'currency': 'USD', 'status': ['paid', 'shipped', 'refunded', 'paid'][i % 4],
                 'created_at': ago(hours=i * 5)} for i in range(14)]
    return [{'results': rows, 'success': True,
             'meta': {'duration': 0.41, 'rows_read': len(rows) * 3, 'rows_written': 0, 'changes': 0,
                      'served_by': 'v3-prod', 'size_after': 48234496, 'changed_db': False}}]


# ---------------------------------------------------------------------------
# Zero Trust

def tunnels():
    def tun(name, status, days, conns):
        return {'id': hexid('tun' + name), 'name': name, 'status': status, 'created_at': ago(days=days),
                'deleted_at': None, 'tun_type': 'cfd_tunnel', 'config_src': 'cloudflare', 'remote_config': True,
                'conns_active_at': ago(days=days - 1) if conns else None, 'conns_inactive_at': None if conns else ago(hours=7),
                'account_tag': ACC, 'metadata': {},
                'connections': [{'id': hexid(f'{name}c{i}'), 'colo_name': c, 'client_id': hexid(f'{name}cl'),
                                 'client_version': '2026.9.1', 'opened_at': ago(hours=30 + i), 'origin_ip': '192.0.2.15',
                                 'is_pending_reconnect': False, 'uuid': hexid(f'{name}c{i}')} for i, c in enumerate(conns)]}
    return [tun('office-nas', 'healthy', 210, ['sin01', 'sin02', 'hkg01', 'hkg03']),
            tun('k8s-prod', 'healthy', 160, ['nrt01', 'nrt02', 'kix01', 'nrt05']),
            tun('home-lab', 'degraded', 90, ['lax01']),
            tun('legacy-erp', 'down', 400, [])]


def tunnel_config(tid):
    return {'tunnel_id': tid, 'version': 7, 'source': 'cloudflare', 'created_at': ago(days=3), 'config': {
        'ingress': [
            {'hostname': 'nas.example.com', 'service': 'https://192.168.1.20:5001', 'originRequest': {'noTLSVerify': True}},
            {'hostname': 'grafana.example.com', 'service': 'http://localhost:3000', 'originRequest': {}},
            {'hostname': 'git.example.com', 'service': 'http://gitea:3000', 'originRequest': {}},
            {'hostname': 'ssh.example.com', 'service': 'ssh://localhost:22', 'originRequest': {}},
            {'service': 'http_status:404'},
        ], 'warp-routing': {'enabled': True}}}


def access_apps():
    def app(name, domain, type_='self_hosted', dur='24h'):
        return {'id': hexid('app' + name), 'uid': hexid('app' + name), 'name': name, 'domain': domain, 'type': type_,
                'session_duration': dur, 'created_at': ago(days=len(name) * 9), 'updated_at': ago(days=len(name)),
                'aud': hexid('aud' + name, 64), 'allowed_idps': [], 'auto_redirect_to_identity': False,
                'app_launcher_visible': True}
    return [app('Grafana', 'grafana.example.com'), app('NAS', 'nas.example.com', dur='8h'),
            app('Gitea', 'git.example.com'), app('Admin panel', 'example.com/admin', dur='1h'),
            app('SSH bastion', 'ssh.example.com', 'ssh', '30m'), app('Google Workspace', 'example.com', 'saas', '24h'),
            app('Staging', 'staging.example.com', dur='12h')]


def gateway_rules():
    def rule(name, action, filters, prec, enabled=True):
        return {'id': hexid('gw' + name), 'name': name, 'action': action, 'filters': filters, 'precedence': prec,
                'enabled': enabled, 'traffic': '', 'identity': '', 'description': '', 'created_at': ago(days=prec),
                'updated_at': ago(days=prec // 2)}
    return [rule(t('Block malware', '拦截恶意软件'), 'block', ['dns'], 1000),
            rule(t('Block phishing', '拦截钓鱼网站'), 'block', ['dns'], 2000),
            rule(t('Allow corporate SaaS', '放行公司 SaaS'), 'allow', ['http'], 3000),
            rule(t('Isolate risky sites', '隔离高风险网站'), 'isolate', ['http'], 4000),
            rule(t('Block P2P', '拦截 P2P'), 'block', ['l4'], 5000),
            rule(t('Log all DNS', '记录全部 DNS'), 'allow', ['dns'], 9000, False)]


def devices():
    def dev(name, typ, os_, email, seen):
        return {'id': hexid('dev' + name), 'name': name, 'device_type': typ, 'os_version': os_, 'version': '2026.9.400.0',
                'user': {'id': hexid('u' + email), 'email': email, 'name': email.split('@')[0]},
                'last_seen': ago(minutes=seen), 'created': ago(days=90), 'updated': ago(minutes=seen),
                'ip': '198.51.100.' + str(len(name) * 7), 'mac_address': None, 'serial_number': None, 'model': ''}
    return [dev("Alex's MacBook Pro", 'mac', '26.0.1', 'alex@example.com', 3),
            dev("Alex's iPhone", 'ios', '26.0', 'alex@example.com', 41),
            dev('Mia-ThinkPad', 'windows', '10.0.26100', 'mia@example.com', 12),
            dev('Sam-Pixel', 'android', '16', 'sam@example.com', 160),
            dev('build-runner-01', 'linux', 'Ubuntu 24.04', 'ops@example.com', 1),
            dev('Jordan-iPad', 'ios', '26.0', 'jordan@example.com', 2900)]


# ---------------------------------------------------------------------------
# Account

def members():
    def mem(first, last, email, roles, status='accepted', tfa=True):
        return {'id': hexid('m' + email), 'status': status,
                'user': {'id': hexid('u' + email), 'email': email, 'first_name': first, 'last_name': last,
                         'two_factor_authentication_enabled': tfa},
                'roles': [{'id': hexid('r' + r), 'name': r, 'description': ''} for r in roles], 'policies': []}
    return [mem('Alex', 'Chen', 'alex@example.com', ['Super Administrator - All Privileges']),
            mem('Mia', 'Wong', 'mia@example.com', ['Administrator']),
            mem('Sam', 'Patel', 'sam@example.com', ['DNS', 'Analytics']),
            mem('Jordan', 'Lee', 'jordan@example.com', ['Workers Admin', 'Cloudflare Pages']),
            mem('Taylor', 'Kim', 'taylor@example.com', ['Billing'], tfa=False),
            mem(None, None, 'contractor@example.net', ['Administrator Read Only'], 'pending', False)]


def roles():
    names = ['Super Administrator - All Privileges', 'Administrator', 'Administrator Read Only', 'Analytics',
             'Billing', 'Cloudflare Pages', 'DNS', 'Firewall', 'Workers Admin', 'Zero Trust']
    return [{'id': hexid('r' + n), 'name': n, 'description': n, 'permissions': {}} for n in names]


def tokens():
    def tok(name, perms, used, exp=None, status='active'):
        return {'id': hexid('tok' + name), 'name': name, 'status': status, 'issued_on': ago(days=120),
                'modified_on': ago(days=30), 'last_used_on': ago(hours=used) if used is not None else None,
                'expires_on': exp, 'not_before': None, 'condition': {},
                'policies': [{'id': hexid('pol' + name), 'effect': 'allow',
                              'resources': {f'com.cloudflare.api.account.{ACC}': '*'},
                              'permission_groups': [{'id': hexid('pg' + p), 'name': p} for p in perms]}]}
    return [tok('Cirrus', ['Zone Read', 'DNS Write', 'Workers Scripts Write', 'Account Analytics Read'], 0),
            tok('CI deploy', ['Workers Scripts Write', 'Pages Write'], 5, ahead(days=80)),
            tok('Terraform', ['Zone Write', 'DNS Write', 'Access: Apps and Policies Write'], 50),
            tok('Grafana metrics', ['Analytics Read'], 1),
            tok('Old backup script', ['R2 Storage Write'], 2000, ago(days=10), 'expired')]


def audit_logs():
    rows = [
        ('alex@example.com', 'update', 'DNS record', 'api.example.com'), ('ci@example.com', 'deploy', 'Worker', 'api-gateway'),
        ('mia@example.com', 'create', 'Access application', 'Grafana'), ('alex@example.com', 'update', 'Zone setting', 'ssl'),
        ('sam@example.com', 'purge', 'Cache', 'example.com'), ('jordan@example.com', 'deploy', 'Pages project', 'acme-blog'),
        ('alex@example.com', 'login', 'Account', 'Acme Studio'), ('mia@example.com', 'create', 'API token', 'CI deploy'),
        ('alex@example.com', 'delete', 'DNS record', 'old.example.com'), ('ci@example.com', 'deploy', 'Worker', 'image-resizer'),
        ('taylor@example.com', 'update', 'Billing profile', 'Acme Studio'), ('sam@example.com', 'create', 'Firewall rule', 'Block /wp-admin'),
    ]
    out = []
    for i, (who, act, typ, rid) in enumerate(rows):
        out.append({'id': hexid(f'audit{i}'), 'when': ago(minutes=i * 97 + 5),
                    'action': {'type': act, 'result': True, 'info': ''},
                    'actor': {'id': hexid('u' + who), 'email': who, 'ip': f'203.0.113.{20 + i}', 'type': 'user'},
                    'resource': {'type': typ, 'id': rid}, 'owner': {'id': ACC}, 'interface': 'UI' if i % 2 else 'API',
                    'newValue': None, 'oldValue': None, 'metadata': {}})
    return out


def ai_models():
    m = [('@cf/meta/llama-3.3-70b-instruct-fp8-fast', 'Text Generation', 'Llama 3.3 70B, quantized for speed.'),
         ('@cf/meta/llama-3.1-8b-instruct', 'Text Generation', 'Multilingual instruction-tuned model.'),
         ('@cf/qwen/qwen2.5-coder-32b-instruct', 'Text Generation', 'Code generation and reasoning.'),
         ('@cf/mistralai/mistral-small-3.1-24b-instruct', 'Text Generation', 'Small, fast, multimodal.'),
         ('@cf/black-forest-labs/flux-1-schnell', 'Text-to-Image', '12B parameter rectified flow transformer.'),
         ('@cf/openai/whisper-large-v3-turbo', 'Automatic Speech Recognition', 'Speech recognition and translation.'),
         ('@cf/baai/bge-m3', 'Text Embeddings', 'Multi-lingual, multi-granularity embeddings.'),
         ('@cf/meta/m2m100-1.2b', 'Translation', 'Many-to-many multilingual translation.'),
         ('@cf/huggingface/distilbert-sst-2-int8', 'Text Classification', 'Sentiment classification.'),
         ('@cf/facebook/detr-resnet-50', 'Object Detection', 'End-to-end object detection.')]
    return [{'id': hexid(n), 'name': n, 'description': d, 'task': {'id': hexid(k), 'name': k, 'description': ''},
             'properties': [], 'tags': []} for n, k, d in m]


# ---------------------------------------------------------------------------
# SSL, rules, email

def cert_packs(z):
    n = z['name']
    return [{'id': hexid('pack' + n), 'type': 'universal', 'hosts': [n, '*.' + n], 'status': 'active',
             'validation_method': 'txt', 'validity_days': 90, 'certificate_authority': 'google',
             'cloudflare_branding': False, 'primary_certificate': hexid('cert' + n),
             'certificates': [{'id': hexid('cert' + n), 'hosts': [n, '*.' + n], 'issuer': 'GoogleTrustServices',
                               'signature': 'ECDSAWithSHA256', 'status': 'active', 'bundle_method': 'ubiquitous',
                               'zone_id': z['id'], 'uploaded_on': ago(days=20), 'modified_on': ago(days=20),
                               'expires_on': ahead(days=70), 'priority': 0}]},
            {'id': hexid('pack2' + n), 'type': 'advanced', 'hosts': [n, 'api.' + n, 'shop.' + n], 'status': 'active',
             'validation_method': 'http', 'validity_days': 30, 'certificate_authority': 'lets_encrypt',
             'cloudflare_branding': False, 'primary_certificate': hexid('cert2' + n),
             'certificates': [{'id': hexid('cert2' + n), 'hosts': [n, 'api.' + n, 'shop.' + n], 'issuer': 'LetsEncrypt',
                               'signature': 'ECDSAWithSHA256', 'status': 'active', 'bundle_method': 'ubiquitous',
                               'zone_id': z['id'], 'uploaded_on': ago(days=8), 'modified_on': ago(days=8),
                               'expires_on': ahead(days=22), 'priority': 0}]}]


def ruleset(phase):
    def r(desc, expr, action, enabled=True, **kw):
        d = {'id': hexid(phase + desc), 'version': '3', 'action': action, 'expression': expr, 'description': desc,
             'enabled': enabled, 'last_updated': ago(days=len(desc)), 'ref': hexid('ref' + desc, 16)}
        d.update(kw)
        return d
    rules = {
        'http_request_firewall_custom': [
            r(t('Block admin outside office', '仅办公室可访问后台'), '(http.request.uri.path wildcard "/admin*" and not ip.src in {203.0.113.0/24})', 'block'),
            r(t('Challenge high-risk countries on login', '登录页对高风险地区质询'), '(http.request.uri.path eq "/login" and ip.src.country in {"XX" "T1"})', 'managed_challenge'),
            r(t('Skip WAF for health checks', '健康检查跳过 WAF'), '(http.request.uri.path eq "/healthz")', 'skip',
              action_parameters={'ruleset': 'current'}),
            r(t('Block bad bots', '拦截恶意爬虫'), '(cf.client.bot) and not (cf.verified_bot_category in {"Search Engine Crawler"})', 'block', False),
        ],
        'http_ratelimit': [
            r(t('API: 100 req/min per IP', 'API：每 IP 每分钟 100 次'), '(starts_with(http.request.uri.path, "/api/"))', 'block',
              ratelimit={'characteristics': ['ip.src', 'cf.colo.id'], 'period': 60, 'requests_per_period': 100, 'mitigation_timeout': 600}),
        ],
        'http_request_dynamic_redirect': [
            r(t('Old blog to new blog', '旧博客跳转新博客'), '(http.host eq "old.example.com")', 'redirect',
              action_parameters={'from_value': {'status_code': 301, 'target_url': {'expression': 'concat("https://blog.example.com", http.request.uri.path)'}}}),
            r('www → apex', '(http.host eq "www.example.com")', 'redirect',
              action_parameters={'from_value': {'status_code': 301, 'target_url': {'value': 'https://example.com'}}}),
        ],
        'http_request_cache_settings': [
            r(t('Cache static assets for a month', '静态资源缓存一个月'), '(http.request.uri.path.extension in {"css" "js" "webp" "woff2"})', 'set_cache_settings',
              action_parameters={'cache': True, 'edge_ttl': {'mode': 'override_origin', 'default': 2592000}}),
            r(t('Bypass cache for API', 'API 不缓存'), '(starts_with(http.request.uri.path, "/api/"))', 'set_cache_settings',
              action_parameters={'cache': False}),
        ],
        'http_request_transform': [
            r(t('Strip tracking parameters', '去掉跟踪参数'), '(http.request.uri.query contains "utm_")', 'rewrite',
              action_parameters={'uri': {'query': {'value': ''}}}),
        ],
        'http_response_headers_transform': [
            r(t('Security headers', '安全响应头'), 'true', 'rewrite',
              action_parameters={'headers': {'X-Frame-Options': {'operation': 'set', 'value': 'DENY'}}}),
        ],
        'http_config_settings': [
            r(t('Disable Rocket Loader on checkout', '结账页关闭 Rocket Loader'), '(http.request.uri.path contains "/checkout")', 'set_config',
              action_parameters={'rocket_loader': False}),
        ],
        'http_request_origin': [
            r(t('Images from R2 origin', '图片走 R2 源站'), '(starts_with(http.request.uri.path, "/img/"))', 'route',
              action_parameters={'host_header': 'assets.example.org', 'origin': {'host': 'assets.example.org'}}),
        ],
        'http_response_compression': [
            r(t('Zstandard for text', '文本使用 Zstandard'), '(http.response.content_type.media_type in {"text/html" "application/json"})', 'compress_response',
              action_parameters={'algorithms': [{'name': 'zstd'}, {'name': 'brotli'}, {'name': 'gzip'}]}),
        ],
        'http_custom_errors': [],
        'http_log_custom_fields': [],
    }.get(phase, [])
    return {'id': hexid('rs' + phase), 'name': 'default', 'description': '', 'kind': 'zone', 'version': '3',
            'phase': phase, 'last_updated': ago(days=3), 'rules': rules}


def email_rules(z):
    n = z['name']

    def rule(name, to, dest, prio):
        return {'id': hexid('er' + to), 'tag': hexid('er' + to), 'name': name, 'enabled': True, 'priority': prio,
                'matchers': [{'type': 'literal', 'field': 'to', 'value': f'{to}@{n}'}],
                'actions': [{'type': 'forward', 'value': [dest]}]}
    return [rule(t('Support inbox', '客服邮箱'), 'support', 'mia@example.net', 0),
            rule(t('Founders', '创始人'), 'hello', 'alex@example.net', 1),
            rule(t('Billing', '账单'), 'billing', 'taylor@example.net', 2),
            rule(t('Security reports', '安全报告'), 'security', 'alex@example.net', 3),
            {'id': hexid('er-worker'), 'tag': hexid('er-worker'), 'name': t('Parse invoices', '解析发票'), 'enabled': True,
             'priority': 4, 'matchers': [{'type': 'literal', 'field': 'to', 'value': f'invoices@{n}'}],
             'actions': [{'type': 'worker', 'value': ['webhook-relay']}]}]


def email_addresses():
    return [{'id': hexid('ea' + e), 'tag': hexid('ea' + e), 'email': e, 'verified': ago(days=40) if v else None,
             'created': ago(days=60), 'modified': ago(days=40)}
            for e, v in (('alex@example.net', True), ('mia@example.net', True), ('taylor@example.net', True),
                         ('ops@example.org', False))]


# ---------------------------------------------------------------------------
# Routing

def page(items, per_page=50):
    return items, {'page': 1, 'per_page': per_page, 'count': len(items), 'total_count': len(items), 'total_pages': 1}


def route(method, path, query, body):
    """Returns (result, result_info) or raises KeyError for 404."""
    p = path
    m = lambda pat: re.fullmatch(pat, p)  # noqa: E731

    if p == '/user':
        return USER, None
    if p in ('/user/tokens/verify',) or re.fullmatch(r'/accounts/[^/]+/tokens/verify', p):
        return {'id': hexid('tokCirrus'), 'status': 'active', 'expires_on': None}, None
    if p == '/accounts':
        return page(accounts())
    if (g := m(r'/accounts/([^/]+)')) and method == 'GET':
        return next((a for a in accounts() if a['id'] == g[1]), accounts()[0]), None
    if p == '/memberships':
        return page([{'id': hexid('ms' + a['id']), 'status': 'accepted', 'account': a, 'roles': ['Administrator'],
                      'permissions': {}} for a in accounts()])
    if p == '/zones':
        acc = (query.get('account.id') or [None])[0]
        name = (query.get('name') or [None])[0]
        zs = [z for z in ZONES if (not acc or z['account']['id'] == acc) and (not name or z['name'] == name)]
        return page(zs)
    if g := m(r'/zones/([^/]+)'):
        return zone_by_id(g[1]), None
    if g := m(r'/zones/([^/]+)/dns_records'):
        recs = dns_records(zone_by_id(g[1]))
        typ = (query.get('type') or [None])[0]
        if typ:
            recs = [r for r in recs if r['type'] == typ]
        return page(recs, 100)
    if m(r'/zones/[^/]+/dns_settings'):
        return {'zone_mode': 'standard', 'flatten_all_cnames': False, 'foundation_dns': False, 'multi_provider': False,
                'ns_ttl': 86400, 'secondary_overrides': False, 'soa': {}, 'nameservers': {'type': 'cloudflare.standard'}}, None
    if g := m(r'/zones/([^/]+)/dnssec'):
        n = zone_by_id(g[1])['name']
        return {'status': 'active', 'flags': 257, 'algorithm': '13', 'key_type': 'ECDSAP256SHA256', 'digest_type': '2',
                'digest_algorithm': 'SHA256', 'key_tag': 2371, 'dnssec_multi_signer': False, 'modified_on': ago(days=200),
                'digest': hexid('ds' + n, 64).upper(),
                'ds': f'{n}. 3600 IN DS 2371 13 2 {hexid("ds" + n, 64).upper()}',
                'public_key': 'mdsswUyr3DPW132mOi8V9xESWE8jTo0dxCjjnopKl+GqJxpVXckHAeF+KkxLbxILfDLUT0rAK9iUzy1L53eKGQ=='}, None
    if m(r'/zones/[^/]+/settings'):
        return zone_settings(), None
    if g := m(r'/zones/[^/]+/settings/([^/]+)'):
        return setting(g[1]), None
    if m(r'/zones/[^/]+/(argo/smart_routing|argo/tiered_caching|cache/tiered_cache_smart_topology_enable|cache/cache_reserve|cache/regional_tiered_cache)'):
        on = 'tiered' in p or 'regional' in p
        return {'id': p.rsplit('/', 1)[1], 'value': 'on' if on else 'off', 'editable': True, 'modified_on': ago(days=30)}, None
    if g := m(r'/zones/([^/]+)/ssl/certificate_packs'):
        return page(cert_packs(zone_by_id(g[1])))
    if m(r'/zones/[^/]+/ssl/universal/settings'):
        return {'enabled': True}, None
    if m(r'/zones/[^/]+/ssl/verification'):
        return [], None
    if g := m(r'/zones/[^/]+/rulesets/phases/([^/]+)/entrypoint'):
        return ruleset(g[1]), None
    if m(r'/zones/[^/]+/rulesets'):
        return page([{k: v for k, v in ruleset(ph).items() if k != 'rules'} for ph in
                     ('http_request_firewall_custom', 'http_ratelimit', 'http_request_dynamic_redirect')])
    if m(r'/zones/[^/]+/managed_headers'):
        return {'managed_request_headers': [{'id': 'add_true_client_ip_headers', 'enabled': True},
                                            {'id': 'add_visitor_location_headers', 'enabled': True}],
                'managed_response_headers': [{'id': 'remove_x-powered-by_header', 'enabled': True},
                                             {'id': 'add_security_headers', 'enabled': True}]}, None
    if m(r'/zones/[^/]+/url_normalization'):
        return {'scope': 'incoming', 'type': 'cloudflare'}, None
    if m(r'/zones/[^/]+/bot_management'):
        return {'fight_mode': True, 'enable_js': True, 'ai_bots_protection': 'block', 'crawler_protection': 'enabled',
                'using_latest_model': True}, None
    if g := m(r'/zones/([^/]+)/email/routing'):
        return {'id': hexid('em'), 'tag': hexid('em'), 'name': zone_by_id(g[1])['name'], 'enabled': True,
                'status': 'ready', 'created': ago(days=200), 'modified': ago(days=20), 'skip_wizard': True}, None
    if g := m(r'/zones/([^/]+)/email/routing/rules'):
        return page(email_rules(zone_by_id(g[1])))
    if m(r'/zones/[^/]+/email/routing/rules/catch_all'):
        return {'id': hexid('catch'), 'tag': hexid('catch'), 'name': 'catch-all', 'enabled': True,
                'matchers': [{'type': 'all'}], 'actions': [{'type': 'forward', 'value': ['alex@example.net']}]}, None
    if g := m(r'/zones/([^/]+)/email/routing/dns'):
        n = zone_by_id(g[1])['name']
        return [{'type': 'MX', 'name': n, 'content': 'route1.mx.cloudflare.net', 'priority': 12, 'ttl': 1},
                {'type': 'MX', 'name': n, 'content': 'route2.mx.cloudflare.net', 'priority': 50, 'ttl': 1},
                {'type': 'TXT', 'name': n, 'content': 'v=spf1 include:_spf.mx.cloudflare.net ~all', 'ttl': 1}], None
    if m(r'/accounts/[^/]+/email/routing/addresses'):
        return page(email_addresses())
    if m(r'/zones/[^/]+/workers/routes'):
        return page([{'id': hexid('wr1'), 'pattern': 'example.com/api/*', 'script': 'api-gateway'},
                     {'id': hexid('wr2'), 'pattern': 'example.com/img/*', 'script': 'image-resizer'},
                     {'id': hexid('wr3'), 'pattern': 'example.com/og/*', 'script': 'og-image'}])
    if m(r'/zones/[^/]+/activation_check|/zones/[^/]+/purge_cache'):
        return {'id': hexid('ok')}, None

    # Workers
    if m(r'/accounts/[^/]+/workers/scripts'):
        return page(scripts())
    if g := m(r'/accounts/[^/]+/workers/scripts/([^/]+)/settings'):
        return worker_settings(unquote(g[1])), None
    if g := m(r'/accounts/[^/]+/workers/scripts/([^/]+)/deployments'):
        return {'deployments': deployments(unquote(g[1]))}, None
    if g := m(r'/accounts/[^/]+/workers/scripts/([^/]+)/versions'):
        return {'items': versions(unquote(g[1]))}, {'page': 1, 'per_page': 20, 'total_count': 6, 'total_pages': 1}
    if m(r'/accounts/[^/]+/workers/scripts/[^/]+/schedules'):
        return {'schedules': [{'cron': '*/15 * * * *', 'created_on': ago(days=40), 'modified_on': ago(days=40)},
                              {'cron': '0 3 * * *', 'created_on': ago(days=40), 'modified_on': ago(days=40)}]}, None
    if m(r'/accounts/[^/]+/workers/scripts/[^/]+/subdomain'):
        return {'enabled': True, 'previews_enabled': True}, None
    if m(r'/accounts/[^/]+/workers/subdomain'):
        return {'subdomain': 'acme'}, None
    if m(r'/accounts/[^/]+/workers/domains'):
        return page([{'id': hexid('wd1'), 'hostname': 'api.example.com', 'service': 'api-gateway', 'environment': 'production',
                      'zone_id': ZONES[0]['id'], 'zone_name': 'example.com'},
                     {'id': hexid('wd2'), 'hostname': 'img.example.com', 'service': 'image-resizer', 'environment': 'production',
                      'zone_id': ZONES[0]['id'], 'zone_name': 'example.com'}])
    if m(r'/accounts/[^/]+/workers/scripts/[^/]+/tails'):
        return [], None

    # Pages
    if m(r'/accounts/[^/]+/pages/projects'):
        return page(pages_projects())
    if g := m(r'/accounts/[^/]+/pages/projects/([^/]+)'):
        return next((x for x in pages_projects() if x['name'] == unquote(g[1])), pages_projects()[0]), None
    if g := m(r'/accounts/[^/]+/pages/projects/([^/]+)/deployments'):
        return page(pages_deployments(unquote(g[1])))
    if g := m(r'/accounts/[^/]+/pages/projects/([^/]+)/domains'):
        proj = next((x for x in pages_projects() if x['name'] == unquote(g[1])), pages_projects()[0])
        return page([{'id': hexid('pdom' + d), 'name': d, 'status': 'active', 'created_on': ago(days=50),
                      'validation_data': {'status': 'active', 'method': 'http'},
                      'verification_data': {'status': 'active'}} for d in proj['domains']])

    # Storage
    if m(r'/accounts/[^/]+/storage/kv/namespaces'):
        return page(kv_namespaces())
    if m(r'/accounts/[^/]+/storage/kv/namespaces/[^/]+/keys'):
        return kv_keys(), {'count': 15, 'cursor': ''}
    if m(r'/accounts/[^/]+/r2/buckets'):
        return r2_buckets(), None
    if m(r'/accounts/[^/]+/r2/buckets/[^/]+/objects'):
        objs, folders = r2_objects((query.get('prefix') or [''])[0])
        return objs, {'is_truncated': False, 'delimited': folders, 'cursor': '', 'per_page': 1000}
    if m(r'/accounts/[^/]+/r2/buckets/[^/]+/domains/custom'):
        return {'domains': [{'domain': 'assets.example.org', 'enabled': True, 'status': {'ownership': 'active', 'ssl': 'active'},
                             'zoneId': ZONES[2]['id'], 'zoneName': 'example.org', 'minTLS': '1.2'}]}, None
    if m(r'/accounts/[^/]+/r2/buckets/[^/]+/domains/managed'):
        return {'bucketId': hexid('b'), 'domain': 'pub-' + hexid('r2pub') + '.r2.dev', 'enabled': False}, None
    if g := m(r'/accounts/[^/]+/r2/buckets/([^/]+)'):
        return {'name': unquote(g[1]), 'creation_date': ago(days=60), 'location': 'APAC', 'storage_class': 'Standard'}, None
    if m(r'/accounts/[^/]+/d1/database'):
        return page(d1_databases())
    if g := m(r'/accounts/[^/]+/d1/database/([^/]+)'):
        return next((d for d in d1_databases() if d['uuid'] == g[1]), d1_databases()[0]), None
    if m(r'/accounts/[^/]+/d1/database/[^/]+/(query|raw)'):
        return d1_query((body or {}).get('sql', '') if isinstance(body, dict) else ''), None

    # Zero Trust
    if m(r'/accounts/[^/]+/cfd_tunnel'):
        return page(tunnels())
    if g := m(r'/accounts/[^/]+/cfd_tunnel/([^/]+)'):
        return next((x for x in tunnels() if x['id'] == g[1]), tunnels()[0]), None
    if g := m(r'/accounts/[^/]+/cfd_tunnel/([^/]+)/configurations'):
        return tunnel_config(g[1]), None
    if g := m(r'/accounts/[^/]+/cfd_tunnel/([^/]+)/connections'):
        tun = next((x for x in tunnels() if x['id'] == g[1]), tunnels()[0])
        return [{'id': hexid('client' + tun['name']), 'arch': 'linux_amd64', 'version': '2026.9.1',
                 'run_at': ago(days=2), 'conns': tun['connections'], 'features': []}], None
    if m(r'/accounts/[^/]+/teamnet/routes'):
        return page([{'id': hexid('route1'), 'network': '192.168.1.0/24', 'comment': t('Office LAN', '办公室局域网'),
                      'tunnel_id': tunnels()[0]['id'], 'tunnel_name': 'office-nas', 'virtual_network_id': None,
                      'created_at': ago(days=100)},
                     {'id': hexid('route2'), 'network': '10.20.0.0/16', 'comment': t('Kubernetes pods', 'Kubernetes Pod 网段'),
                      'tunnel_id': tunnels()[1]['id'], 'tunnel_name': 'k8s-prod', 'virtual_network_id': None,
                      'created_at': ago(days=80)}])
    if m(r'/accounts/[^/]+/access/apps'):
        return page(access_apps())
    if m(r'/accounts/[^/]+/gateway/rules'):
        return gateway_rules(), None
    if m(r'/accounts/[^/]+/devices'):
        return devices(), None

    # Account
    if m(r'/accounts/[^/]+/members'):
        return page(members())
    if m(r'/accounts/[^/]+/roles'):
        return page(roles())
    if m(r'/user/tokens|/accounts/[^/]+/tokens'):
        return page(tokens())
    if m(r'/accounts/[^/]+/audit_logs'):
        return page(audit_logs())
    if m(r'/accounts/[^/]+/ai/models/search'):
        return page(ai_models())
    if g := m(r'/accounts/[^/]+/ai/run/(.+)'):
        return {'response': t('Edge caching stores copies of your content in data centres close to your visitors, '
                              'so pages load faster and your origin handles fewer requests.',
                              '边缘缓存会把内容的副本存放在离访问者最近的数据中心，页面加载更快，源站的请求也更少。')}, None
    if m(r'/accounts/[^/]+/rules/lists'):
        return page([{'id': hexid('l1'), 'name': 'office_ips', 'kind': 'ip', 'num_items': 12, 'description': t('Office egress IPs', '办公室出口 IP'),
                      'created_on': ago(days=200), 'modified_on': ago(days=3)},
                     {'id': hexid('l2'), 'name': 'bad_asns', 'kind': 'asn', 'num_items': 37, 'description': t('Abusive networks', '恶意网络'),
                      'created_on': ago(days=150), 'modified_on': ago(days=9)},
                     {'id': hexid('l3'), 'name': 'legacy_redirects', 'kind': 'redirect', 'num_items': 214,
                      'description': t('Old URLs to new site', '旧网址跳转'), 'created_on': ago(days=90), 'modified_on': ago(days=1)}])
    raise KeyError(p)


def generic(method, path):
    """Unknown endpoints: an empty list for collections, an empty object otherwise."""
    last = path.rstrip('/').rsplit('/', 1)[-1]
    if method == 'GET' and not re.fullmatch(r'[0-9a-f-]{16,}', last):
        return page([])
    return {}, None


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        sys.stderr.write('%s %s\n' % (self.command, self.path))

    def _send(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle(self):
        u = urlparse(self.path)
        path = u.path
        if path.startswith('/client/v4'):
            path = path[len('/client/v4'):]
        query = parse_qs(u.query)
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n) if n else b''
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = None
        if path == '/graphql':
            return self._send(200, {'data': graphql(body or {}), 'errors': None})
        if re.fullmatch(r'/accounts/[^/]+/workers/scripts/[^/]+/content(/v2)?', path):
            data = WORKER_SRC.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/javascript+module')
            self.send_header('cf-entrypoint', 'index.js')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if re.fullmatch(r'/accounts/[^/]+/storage/kv/namespaces/[^/]+/values/.+', path):
            data = json.dumps({'enabled': True, 'rollout': 50, 'owner': 'growth'}, indent=2).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.command != 'GET' and not re.search(r'/(query|raw|ai/run/.+|purge_cache|activation_check)$', path):
            return self._send(200, {'success': True, 'errors': [], 'messages': [], 'result': body if isinstance(body, dict) else {}})
        try:
            result, info = route(self.command, path, query, body)
        except KeyError:
            result, info = generic(self.command, path)
        env = {'success': True, 'errors': [], 'messages': [], 'result': result}
        if info is not None:
            env['result_info'] = info
        self._send(200, env)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _handle


def main():
    global LANG
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--port', type=int, default=8787)
    ap.add_argument('--lang', choices=['en', 'zh'], default='en', help='language of the demo names and comments')
    a = ap.parse_args()
    LANG = a.lang
    srv = ThreadingHTTPServer(('127.0.0.1', a.port), Handler)
    print(f'demo API on http://127.0.0.1:{a.port}/client/v4 ({LANG})', flush=True)
    srv.serve_forever()


if __name__ == '__main__':
    main()
