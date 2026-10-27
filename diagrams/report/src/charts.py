import datetime as dt, html
def load(f):
    rows=[]
    for line in open(f):
        p=line.rstrip('\n').split('\t')
        if len(p)<3 or line.startswith('#'): continue
        t=dt.datetime.strptime(p[0],'%H:%M:%S.%f'); L=float(p[2])
        rows.append(((t-dt.datetime(1900,1,1)).total_seconds(), p[1], L))
    return rows
FONT="'Noto Sans KR',sans-serif"
C=dict(surface='#ffffff',text='#0b0b0b',text2='#52514e',muted='#8a8984',grid='#e8e7e3',axis='#c9c8c2',s1='#2a78d6',crit='#d03b3b',band='#fbe9e9')
CSS=f"""<link href="https://fonts.googleapis.com/css2?family=Noto+Sans+KR:wght@400;500;700&display=swap" rel="stylesheet">
<style>body{{margin:0;background:{C['surface']};font-family:{FONT};color:{C['text']}}} #fig{{padding:28px 32px 20px;background:{C['surface']};display:inline-block}}
h1{{font-size:22px;font-weight:700;margin:0 0 4px}} .sub{{font-size:14px;color:{C['text2']};margin:0 0 14px}} .src{{font-size:12px;color:{C['muted']};margin-top:8px}}
svg text{{font-family:{FONT}}}</style>"""

# ---------- Chart 1: V6 direct vs proxy ----------
def v6panel(rows, title, n, fails, xoff, W=980, H=230):
    # t0 = start of first failed request
    f0=[r for r in rows if r[1]!='200'][0]; t0=f0[0]-f0[2]
    # impact window end: last slow (>0.5s) request ending within 20s after t0
    end=max(r[0] for r in rows if r[0]-t0<20 and r[0]>=t0 and (r[1]!='200' or r[2]>0.5))
    win=end-t0
    ml,mr,mt,mb=56,16,40,34; pw=W-ml-mr; ph=H-mt-mb
    X0,X1=-20,60; Y1=5.5
    sx=lambda x: ml+(x-X0)/(X1-X0)*pw; sy=lambda y: mt+ph-(y/Y1)*ph
    s=[f'<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg">']
    s.append(f'<text x="{ml}" y="20" font-size="16" font-weight="700" fill="{C["text"]}">{title}</text>')
    s.append(f'<text x="{W-mr}" y="20" font-size="14" text-anchor="end" fill="{C["text2"]}">요청 {n} · 실패 {fails}</text>')
    # band
    s.append(f'<rect x="{sx(0):.1f}" y="{mt}" width="{sx(win)-sx(0):.1f}" height="{ph}" fill="{C["band"]}"/>')
    s.append(f'<text x="{sx(win)+8:.1f}" y="{mt+18}" font-size="14" font-weight="700" fill="{C["crit"]}">앱 영향 약 {win:.1f}초</text>')
    for y in [0,1,2,3,4,5]:
        s.append(f'<line x1="{ml}" x2="{W-mr}" y1="{sy(y):.1f}" y2="{sy(y):.1f}" stroke="{C["grid"] if y else C["axis"]}" stroke-width="1"/>')
        s.append(f'<text x="{ml-8}" y="{sy(y)+4:.1f}" font-size="12" text-anchor="end" fill="{C["muted"]}">{y}s</text>')
    for x in range(-20,61,10):
        s.append(f'<text x="{sx(x):.1f}" y="{H-12}" font-size="12" text-anchor="middle" fill="{C["muted"]}">{x:+d}s</text>' if x else f'<text x="{sx(x):.1f}" y="{H-12}" font-size="12" text-anchor="middle" fill="{C["text2"]}">0</text>')
    pts=[(r[0]-t0,r) for r in rows if X0<=r[0]-t0<=X1]
    ok=[(x,r) for x,r in pts if r[1]=='200']
    s.append('<polyline fill="none" stroke="%s" stroke-width="2" stroke-linejoin="round" points="%s"/>'%(C['s1'],' '.join(f'{sx(x):.1f},{sy(min(r[2],Y1)):.1f}' for x,r in pts if r[1]=='200' or True)))
    for x,r in pts:
        if r[1]!='200':
            cx,cy=sx(x),sy(min(r[2],Y1)); d=6
            s.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="9" fill="{C["surface"]}"/>')
            s.append(f'<path d="M{cx-d} {cy-d}L{cx+d} {cy+d}M{cx+d} {cy-d}L{cx-d} {cy+d}" stroke="{C["crit"]}" stroke-width="3" stroke-linecap="round"/>')
    fx=[sx(x) for x,r in pts if r[1]!='200']
    s.append(f'<text x="{fx[0]-12:.1f}" y="{sy(5)+5:.1f}" font-size="13" text-anchor="end" fill="{C["text2"]}">✕ 실패 (5초 시간 초과)</text>')
    s.append('</svg>'); return '\n'.join(s), win
d=load('v6-155140.tsv'); p=load('v6p-200003.tsv')
a,wa=v6panel(d,'① 직접 연결 (was → RDS)',len(d),sum(r[1]!='200' for r in d),0)
b,wb=v6panel(p,'② RDS Proxy 경유 (was → Proxy → RDS)',len(p),sum(r[1]!='200' for r in p),0)
open('v6.html','w').write(f"""<html><head>{CSS}</head><body><div id="fig">
<h1>RDS 장애 조치 중 응답 시간: 직접 연결 vs RDS Proxy</h1>
<p class="sub">curl 요청마다 응답 시간을 찍었다. 선은 요청이 끝난 시각에 찍었고, 가로축 0 은 첫 실패 요청이 시작된 시각이다. 각 1회 측정, 요청 간격 0.5~1초.</p>
{a}<div style="height:10px"></div>{b}
<div class="src">출처: logs/verify-20261026/v6-155140.tsv, v6p-200003.tsv (2026-10-26). 앱 영향 = 첫 실패 요청 시작 ~ 마지막 지연(0.5초 초과) 응답까지.</div>
</div></body></html>""")
print('v6 windows',round(wa,2),round(wb,2),len(d),len(p))

# ---------- Chart 2: zero-downtime small multiples ----------
runs=[('v2-143357.tsv','롤링 배포 ①'),('v2-143904.tsv','롤링 배포 ②'),('v2c-152419.tsv','롤링 배포 ③'),('v7-154629.tsv','노드 drain'),('v7-154915.tsv','drain 뒤 재배치')]
def small(rows,title,W=196,H=200):
    ml,mr,mt,mb=34,8,46,28; pw=W-ml-mr; ph=H-mt-mb
    t0=rows[0][0]; X1=max(240, rows[-1][0]-t0); Y1=1.5
    sx=lambda x: ml+x/X1*pw; sy=lambda y: mt+ph-(y/Y1)*ph
    nf=sum(r[1]!='200' for r in rows)
    s=[f'<svg width="{W}" height="{H}" xmlns="http://www.w3.org/2000/svg">',
       f'<text x="{ml}" y="16" font-size="14" font-weight="700" fill="{C["text"]}">{title}</text>',
       f'<text x="{ml}" y="34" font-size="12.5" fill="{C["text2"]}">요청 {len(rows)} · 실패 <tspan font-weight="700" fill="{C["text"]}">{nf}</tspan></text>']
    for y in [0,0.5,1,1.5]:
        s.append(f'<line x1="{ml}" x2="{W-mr}" y1="{sy(y):.1f}" y2="{sy(y):.1f}" stroke="{C["grid"] if y else C["axis"]}"/>')
        s.append(f'<text x="{ml-5}" y="{sy(y)+4:.1f}" font-size="11" text-anchor="end" fill="{C["muted"]}">{y:g}s</text>')
    for x in [0,120,240]:
        s.append(f'<text x="{sx(x):.1f}" y="{H-8}" font-size="11" text-anchor="middle" fill="{C["muted"]}">{x//60}분</text>')
    s.append('<polyline fill="none" stroke="%s" stroke-width="1.5" stroke-linejoin="round" points="%s"/>'%(C['s1'],' '.join(f'{sx(r[0]-t0):.1f},{sy(min(r[2],Y1)):.1f}' for r in rows)))
    s.append('</svg>'); return '\n'.join(s), len(rows), nf
parts=[small(load(f),t) for f,t in runs]
tot=sum(x[1] for x in parts); totf=sum(x[2] for x in parts)
open('nodown.html','w').write(f"""<html><head>{CSS}</head><body><div id="fig">
<h1>무중단 측정: 롤링 배포 3회 · 노드 drain · 재배치 중 응답 시간</h1>
<p class="sub">전체 요청 {tot:,}건 중 200 아닌 응답 {totf}건. 응답 시간은 모두 1.5초 안쪽이었다.</p>
<div style="display:flex;gap:2px">{''.join(x[0] for x in parts)}</div>
<div class="src">출처: logs/verify-20261026/v2-143357·v2-143904·v2c-152419·v7-154629·v7-154915.tsv (2026-10-26), curl 0.5~1초 간격. 재배치 = uncordon 뒤 rollout restart(15:49:30)</div>
</div></body></html>""")
print('nodown',tot,totf)
