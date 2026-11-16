#!/usr/bin/env python3
"""Live UTF-8 SSE equivalence check against an already-started server."""
import json
from pathlib import Path
import subprocess

proof = Path(__file__).resolve().parents[1] / 'proof'
key = (Path.home() / '.sensenova/api-key').read_text().strip()
config = 'header = "Authorization: Bearer ' + key + '"\n'
body = {'messages': [{'role': 'user', 'content': 'Repeat the following text exactly, without quotes or explanation: Cafe\u0301 👩\u200d💻 中文'}], 'max_tokens': 64, 'temperature': 0}
answers = []
for stream in [False, True]:
    body['stream'] = stream
    name = 'unicode-stream' if stream else 'unicode'
    request = proof / (name + '-request.json')
    request.write_text(json.dumps(body))
    result = subprocess.run(['curl', '-NsSf', '--max-time', '120', '--config', '-', '-H', 'Content-Type: application/json', '--data-binary', '@' + str(request), 'http://127.0.0.1:8003/v1/chat/completions'], input=config, text=True, capture_output=True, check=True)
    (proof / (name + ('.sse' if stream else '.json'))).write_text(result.stdout)
    if stream:
        assert 'data: [DONE]' in result.stdout
        chunks = []
        for line in result.stdout.splitlines():
            if not line.startswith('data: ') or line == 'data: [DONE]': continue
            value = json.loads(line[6:])
            assert 'error' not in value, value
            chunks.append(value['choices'][0]['delta'].get('content', ''))
        answers.append(''.join(chunks))
    else: answers.append(json.loads(result.stdout)['choices'][0]['message']['content'])
assert answers[0].encode() == answers[1].encode()
assert any(ord(c) > 127 for c in answers[0])
results = {'stream_matches_nonstream_utf8_bytes': True, 'unicode_present': True, 'answer': answers[0]}
(proof / 'unicode-results.json').write_text(json.dumps(results, indent=2, ensure_ascii=False))
print(json.dumps(results, indent=2, ensure_ascii=False))
