# CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
# 채점 연출 불꽃 효과음 합성 (외부 음원 없음): FireworkBang1~3, FireworkLaunch
# 사용: uv run --with numpy python3 scripts/make_fireworks_sfx.py <출력 폴더>
#       그 뒤 afconvert -f m4af -d aac -b 128000 <wav> CoNo/Resources/<이름>.m4a
import numpy as np, struct, sys
SR = 44100
rng = np.random.default_rng(7)

def onepole_lp(x, cutoff):  # cutoff: array or scalar (Hz)
    cutoff = np.broadcast_to(np.asarray(cutoff, float), x.shape)
    a = np.exp(-2*np.pi*cutoff/SR); y = np.zeros_like(x); s = 0.0
    for i in range(len(x)):
        s = (1-a[i])*x[i] + a[i]*s; y[i] = s
    return y

def hp(x, cutoff):
    return x - onepole_lp(x, cutoff)

def reverb(x, seconds=1.1, mix=0.22, seed=1):
    r = np.random.default_rng(seed); n = int(seconds*SR)
    ir = r.standard_normal(n) * np.exp(-np.arange(n)/(0.28*SR)); ir[:int(0.012*SR)] = 0
    ir = onepole_lp(ir, 3500); ir /= np.sqrt((ir**2).sum())
    wet = np.convolve(x, ir)[:len(x)+n]; wet = np.pad(wet, (0, len(x)+n-len(wet)))
    out = np.concatenate([x, np.zeros(n)]); return out + mix*wet

def bang(seed, low=48, body_ms=260, crackle=True, length=2.4):
    r = np.random.default_rng(seed); n = int(length*SR); t = np.arange(n)/SR
    noise = r.standard_normal(n)
    # 몸통: 밝게 시작해 빠르게 어두워지는 폭발음
    cutoff = 250 + 6500*np.exp(-t/0.05)
    body = onepole_lp(onepole_lp(noise, cutoff), cutoff) * np.exp(-t/(body_ms/1000)) * np.minimum(1, t/0.002)
    # 첫 순간 딱 소리
    click = hp(noise, 2000) * np.exp(-t/0.004)
    # 가슴을 치는 저음
    f = low * (1 + 0.6*np.exp(-t/0.03)); phase = 2*np.pi*np.cumsum(f)/SR
    thump = np.sin(phase) * np.exp(-t/0.16) * np.minimum(1, t/0.004)
    x = 0.9*body/np.abs(body).max() + 0.5*click/np.abs(click).max() + 0.8*thump
    if crackle:
        # 잔불 지지직: 0.35초부터 1.6초까지 점점 드물게
        crack = np.zeros(n)
        count = r.integers(55, 80)
        for _ in range(count):
            at = 0.35 + r.exponential(0.35)
            if at > 1.9: continue
            i = int(at*SR); L = int(r.uniform(0.0008, 0.003)*SR)
            if i+L >= n: continue
            burst = hp(r.standard_normal(L), 1500) * np.exp(-np.arange(L)/(L/3))
            crack[i:i+L] += burst * r.uniform(0.25, 1.0) * np.exp(-(at-0.35)/0.8)
        x += 0.35*crack/ (np.abs(crack).max()+1e-9)
    return x

def launch(seed=3, length=0.75):
    r = np.random.default_rng(seed); n = int(length*SR); t = np.arange(n)/SR
    # 로켓이 올라가는 쉿- 소리 + 희미한 휘파람
    noise = r.standard_normal(n)
    env = np.minimum(1, t/0.05) * np.exp(-np.maximum(0, t-0.5)/0.06)
    hiss = hp(onepole_lp(noise, 2500 + 5000*t/length), 1200) * env
    f = 900 + 1700*(t/length)**1.3; whistle = np.sin(2*np.pi*np.cumsum(f)/SR) * env * 0.12
    x = hiss/np.abs(hiss).max()*0.5 + whistle
    return x

def stereo(x, pan=0.0, width=0.2, seed=0):
    r = np.random.default_rng(seed)
    d = int(r.uniform(0.0002, 0.0009)*SR)
    L = x.copy(); R = np.concatenate([np.zeros(d), x[:-d]]) if d else x.copy()
    gl, gr = np.cos((pan+1)*np.pi/4), np.sin((pan+1)*np.pi/4)
    return np.stack([L*gl*1.4, R*gr*1.4], axis=1)

def write(path, y, peak_db=-1.0):
    y = y / np.abs(y).max() * 10**(peak_db/20)
    data = y.astype('<f4').tobytes()
    hdr = b'RIFF'+struct.pack('<I',36+len(data))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,3,2,SR,SR*8,8,32)+b'data'+struct.pack('<I',len(data))
    open(path,'wb').write(hdr+data)

out = sys.argv[1]
for k,(seed,low,body) in enumerate([(11,46,280),(23,58,220),(37,40,340)], start=1):
    x = reverb(bang(seed, low, body), mix=0.25, seed=seed)
    write(f"{out}/FireworkBang{k}.wav", stereo(x, seed=seed), peak_db=-1.5)
write(f"{out}/FireworkLaunch.wav", stereo(reverb(launch(), 0.6, 0.15), seed=5), peak_db=-9)
print("ok")
