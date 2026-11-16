#!/usr/bin/env python3
"""Mac-only acceptance driver. curl performs all API requests; never logs the key."""
import base64
import concurrent.futures
import json
import os
import re
from pathlib import Path
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
PROOF = ROOT / 'proof'
PROOF.mkdir(exist_ok=True)
BASE = 'http://127.0.0.1:8003'
KEY = (Path.home() / '.sensenova/api-key').read_text().strip()
PID = int((PROOF / 'server.pid').read_text())
CONFIG = 'header = "Authorization: Bearer ' + KEY + '"\n'
QUESTION = 'Describe this game screenshot in detail: what screen is it, what ship is shown, what is highlighted, and list any text you can read.'
image = (Path.home() / 'sensenova/vqa-test.png').read_bytes()
request = {'messages': [{'role': 'user', 'content': [{'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + base64.b64encode(image).decode()}}, {'type': 'text', 'text': QUESTION}]}], 'max_tokens': 512, 'temperature': 0}
(PROOF / 'vqa-request.json').write_text(json.dumps(request))
(PROOF / 'cli-reference.txt').write_text((Path.home() / 'sensenova/vqa-sn.txt').read_text())

metrics = {}
stop = threading.Event()
samples = []
def sample_memory():
    while not stop.is_set():
        result = subprocess.run(['ps', '-o', 'rss=', '-p', str(PID)], text=True, capture_output=True)
        if result.stdout.strip():
            samples.append({'time': time.time(), 'rss_kib': int(result.stdout.strip())})
        stop.wait(0.25)
threading.Thread(target=sample_memory, daemon=True).start()

def curl(name, route, data=None, extra=(), auth=True):
    args = ['curl', '--silent', '--show-error', '--max-time', '300', '--config', '-', '-o', str(PROOF / (name + '.json')), '-w', '%{json}', BASE + route]
    if data is not None:
        file = PROOF / (name + '-request.json')
        file.write_text(json.dumps(data))
        args += ['-H', 'Content-Type: application/json', '--data-binary', '@' + str(file)]
    args += list(extra)
    result = subprocess.run(args, input=CONFIG if auth else '', text=True, capture_output=True, check=True)
    value = json.loads(result.stdout)
    result_metrics = {key: value.get(key) for key in ['http_code', 'time_starttransfer', 'time_total', 'size_download']}
    print(name, result_metrics, flush=True)
    return result_metrics

def footprint(name):
    result = subprocess.run(['/usr/bin/footprint', '-p', str(PID), '-f', 'bytes'], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (PROOF / (name + '-footprint.txt')).write_text(result.stdout)

try:
    metrics['health'] = curl('health-start', '/health', auth=False)
    metrics['models'] = curl('models', '/v1/models')
    metrics['unauthorized'] = curl('unauthorized', '/v1/models', auth=False)
    metrics['bad_url'] = curl('bad-url', '/v1/chat/completions', {'messages': [{'role': 'user', 'content': [{'type': 'image_url', 'image_url': {'url': 'https://example.com/no.png'}}]}]})
    metrics['bad_size'] = curl('bad-size', '/v1/images/generations', {'prompt': 'cat', 'size': '1025x1024'})
    footprint('default-startup')
    metrics['warmup'] = curl('warmup', '/v1/chat/completions', request)
    footprint('idle')
    metrics['warm_vqa'] = curl('vqa-warm', '/v1/chat/completions', request)
    stream = dict(request, stream=True)
    stream_path = PROOF / 'vqa-stream-request.json'
    stream_path.write_text(json.dumps(stream))
    args = ['curl', '-N', '--silent', '--show-error', '--max-time', '300', '--config', '-', '-H', 'Content-Type: application/json', '--data-binary', '@' + str(stream_path), BASE + '/v1/chat/completions']
    start = time.monotonic()
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    process.stdin.write(CONFIG); process.stdin.close()
    stamps = []; first = None; pieces = []; count = 0
    with (PROOF / 'vqa-stream.sse').open('w') as output:
        for line in process.stdout:
            elapsed = time.monotonic() - start
            output.write(line)
            if line.startswith('data: '):
                stamps.append({'seconds': elapsed, 'data': line[6:].strip()})
                if line.strip() != 'data: [DONE]':
                    value = json.loads(line[6:]); delta = value.get('choices', [{}])[0].get('delta', {}).get('content', '')
                    if delta:
                        if first is None: first = elapsed
                        pieces.append(delta); count += 1
    process.wait()
    assert process.returncode == 0, process.stderr.read()
    metrics['stream'] = {'first_content_seconds': first, 'total_seconds': time.monotonic() - start, 'content_chunks': count}
    (PROOF / 'vqa-stream-timestamps.json').write_text(json.dumps(stamps, indent=2))
    (PROOF / 'vqa-stream-answer.txt').write_text(''.join(pieces))
    print('stream', metrics['stream'], flush=True)
    for i in range(3): metrics['sequential_' + str(i+1)] = curl('vqa-sequential-' + str(i+1), '/v1/chat/completions', request)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(curl, 'vqa-concurrent-' + str(i+1), '/v1/chat/completions', request) for i in range(2)]
        time.sleep(1)
        metrics['queue_health'] = curl('health-queued', '/health', auth=False)
        footprint('during-request')
        for i, future in enumerate(futures): metrics['concurrent_' + str(i+1)] = future.result()
    # While T2I occupies the worker, fill all eight waiting slots and force 429.
    with concurrent.futures.ThreadPoolExecutor(max_workers=14) as pool:
        generation = pool.submit(curl, 'generation', '/v1/images/generations', {'prompt': 'A small red sailboat on a calm blue mountain lake at sunrise, realistic photography, no text.', 'size': '1024x1024', 'seed': 42})
        time.sleep(1)
        short = {'messages': [{'role': 'user', 'content': 'Say hello.'}], 'max_tokens': 1}
        futures = [pool.submit(curl, 'overflow-' + str(i), '/v1/chat/completions', short) for i in range(12)]
        time.sleep(0.3)
        metrics['full_queue'] = curl('health-full-queue', '/health', auth=False)
        metrics['generation'] = generation.result()
        metrics['overflow'] = [f.result() for f in futures]
    assert any(v['http_code'] == 429 for v in metrics['overflow'])
    def decode(name):
        data = json.loads((PROOF / (name + '.json')).read_text())
        assert 'data' in data, data
        (PROOF / (name + '.png')).write_bytes(base64.b64decode(data['data'][0]['b64_json']))
    decode('generation')
    metrics['edit'] = curl('edit', '/v1/images/edits', extra=['-F', 'image=@' + str(PROOF / 'generation.png'), '-F', 'prompt=Change the red sail to bright yellow. Preserve the boat, lake, mountains, camera angle and lighting.', '-F', 'size=1024x1024', '-F', 'seed=42'])
    decode('edit')
    # Exercise history and two references on the actual model, beyond parsing tests.
    uri = 'data:image/png;base64,' + base64.b64encode((PROOF / 'generation.png').read_bytes()).decode()
    uri2 = 'data:image/png;base64,' + base64.b64encode((PROOF / 'edit.png').read_bytes()).decode()
    history = {'messages': [{'role': 'system', 'content': 'Answer briefly in English.'}, {'role': 'user', 'content': [{'type': 'image_url', 'image_url': {'url': uri}}, {'type': 'text', 'text': 'Remember this boat.'}]}, {'role': 'assistant', 'content': 'I see the boat.'}, {'role': 'user', 'content': [{'type': 'image_url', 'image_url': {'url': uri2}}, {'type': 'text', 'text': 'Compare the sail color with the previous image.'}]}], 'max_tokens': 100}
    metrics['history'] = curl('history-multi-image', '/v1/chat/completions', history)
    metrics['health_final'] = curl('health-final', '/health', auth=False)
    footprint('final-idle')
    memory = (PROOF / 'final-idle-footprint.txt').read_text()
    metrics['final_physical_footprint_bytes'] = int(re.search(r'phys_footprint: (\d+) B', memory)[1])
    metrics['peak_physical_footprint_bytes'] = int(re.search(r'phys_footprint_peak: (\d+) B', memory)[1])
    cli = (PROOF / 'cli-reference.txt').read_text().split('tok/s):\n', 1)[-1].strip()
    answer = json.loads((PROOF / 'vqa-warm.json').read_text())['choices'][0]['message']['content'].strip()
    (PROOF / 'vqa-answer.txt').write_text(answer + '\n')
    metrics['cli_exact_match'] = answer == cli
    metrics['stream_exact_match'] = answer == ''.join(pieces).strip()
    metrics['all_vqa_identical'] = all(json.loads((PROOF / (n + '.json')).read_text())['choices'][0]['message']['content'].strip() == answer for n in ['warmup'] + ['vqa-sequential-' + str(i) for i in range(1, 4)] + ['vqa-concurrent-' + str(i) for i in range(1, 3)])
finally:
    stop.set()
    metrics['sampled_peak_rss_kib'] = max((v['rss_kib'] for v in samples), default=0)
    (PROOF / 'memory-samples.json').write_text(json.dumps(samples, indent=2))
    (PROOF / 'metrics.json').write_text(json.dumps(metrics, indent=2))
