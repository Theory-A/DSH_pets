"""Render the README GIF from shipped sprites and a clearly labelled mock window.
Development-only: Pillow. No screenshots, new artwork generation, or runtime changes.
"""
from pathlib import Path
from functools import lru_cache
import json, math, os
from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'docs'; OUT.mkdir(exist_ok=True)
CHECKS=ROOT/'artifacts'/'demo-checks'; CHECKS.mkdir(parents=True,exist_ok=True)
W,H=1000,610; FLOOR=228; SCALE=2; FRAME_MS=80; COUNT=160
BREEDS=('silver-siberian','tuxedo','sheltie')
SHEETS=[Image.open(ROOT/f'art/{b}-colony.png').convert('RGBA') for b in BREEDS]
MINIS=[Image.open(ROOT/f'art/{b}-mini.png').convert('RGBA') for b in BREEDS]
FONT=os.environ.get('DSH_PETS_FONT','/System/Library/Fonts/Hiragino Sans GB.ttc')
@lru_cache(None)
def font(size):return ImageFont.truetype(FONT,size)
C={'paper':'#f4f2f8','ink':'#272638','muted':'#79758e','shadow':'#ddd9e8','window':'#151e2e','sidebar':'#111927','line':'#2d3950','white':'#edf0f8','soft':'#9ba8bf','green':'#66dec1','amber':'#ffd18a','purple':'#bca5fa','selected':'#25324a','card':'#1b273a'}
def text(d,x,y,s,size=16,fill=None):d.text((x,y),s,font=font(size),fill=fill or C['ink'],anchor='lt')
def rr(d,box,fill,r=10,outline=None):d.rounded_rectangle(box,radius=r,fill=fill,outline=outline)
def frame_cell(sheet,i,cw,ch,cols):return sheet.crop(((i%cols)*cw,(i//cols)*ch,(i%cols+1)*cw,(i//cols+1)*ch))
def state(t):
    if t<4:return 'WORKING / 工作中',['thinking']*3,[(0,'subagent'),(1,'subagent'),(2,'job')]
    if t<7:
        minis=[(1,'subagent')]
        if t<5:minis.insert(0,(0,'subagent'))
        if t<5.5:minis.append((2,'job'))
        return 'WAITING / 等待回复',['thinking','awaiting','thinking' if t<5.5 else 'lying'],minis
    if t<10:return 'RESTING / 休息中',['lying' if t<8 else 'sleep','sleep','stretch' if t>9.3 else 'sleep'],[]
    return 'WANDERING / 自由活动',['walk','rest','stretch' if t<10.6 else 'rest'],[]
def pose_index(pose,t):
    if pose=='walk':return int((t-10)*6)%4
    if pose=='thinking':return 6+int(t*2)%2
    if pose=='awaiting':return 9 if 6.24<=t<6.40 else 8
    return {'rest':4,'sleep':5,'lying':10,'stretch':11}[pose]
def draw_main(layer,slot,pose,t):
    x=[28,342,658][slot]; facing=True
    if pose=='walk':
        elapsed=t-10; distance=36*(elapsed if elapsed<1.4 else 2.8-elapsed)
        x+=round(distance);facing=elapsed<1.4
    sprite=frame_cell(SHEETS[slot],pose_index(pose,t),96,80,4)
    if not facing:sprite=ImageOps.mirror(sprite)
    sprite=sprite.resize((192,160),Image.Resampling.NEAREST)
    layer.alpha_composite(sprite,(x,FLOOR-160+(4 if pose in ('lying','sleep') else 0)))
    return x

def draw_mini(layer,slot,role,t):
    # Match native CatView's 58x56 panel, 48x40 body and pixel-glyph coordinates.
    mini=Image.new('RGBA',(58,56));body=frame_cell(MINIS[slot],int(t*2)%2,48,40,2)
    mini.alpha_composite(body,(5,16));d=ImageDraw.Draw(mini)
    def rect(x,y,w,h,color):d.rectangle((x,56-y-h,x+w-1,55-y),fill=color)
    for a in [(24,38,18,14),(22,40,22,10)]:rect(*a,'#383838')
    for a in [(25,39,16,12),(23,41,20,8),(30,34,3,3),(28,30,2,2)]:rect(*a,'#ffffff')
    if role=='job':
        for row,line in enumerate(['10101','01110','11111','01110','10101']):
            for col,v in enumerate(line):
                if v=='1':rect(31+col,47-row,1,1,'#2e2e2e')
    else:
        for x in [27,32,37]:rect(x,44,2,2,'#2e2e2e')
    layer.alpha_composite(mini.resize((116,112),Image.Resampling.NEAREST),([212,526,842][slot],FLOOR-112))

def render(t):
    heading,poses,minis=state(t);subs=sum(r=='subagent' for _,r in minis);jobs=len(minis)-subs
    active=sum(p in ('thinking','awaiting') for p in poses)
    im=Image.new('RGB',(W,H),C['paper']);d=ImageDraw.Draw(im)
    text(d,32,20,'DSH Pets',32)
    text(d,34,63,'Your agents, with paws. / 让任务多一点陪伴。',15,C['muted'])
    rr(d,(686,28,966,67),'#e7e1f4',r=18)
    text(d,706,40,heading,15)
    rr(d,(30,FLOOR+6,970,493),C['shadow'],r=18)
    rr(d,(30,FLOOR,970,487),C['window'],r=16,outline=C['line'])
    d.line((31,FLOOR,969,FLOOR),fill='#6e6889',width=2)
    for x,c in [(52,'#fb746c'),(74,'#edc45f'),(96,'#63c999')]:d.ellipse((x,246,x+10,256),fill=c)
    text(d,356,244,'DeepSeek Harness · Mock UI / 模拟界面',14,C['soft'])
    d.line((31,273,969,273),fill=C['line'])
    d.rectangle((31,274,208,470),fill=C['sidebar']);d.line((209,274,209,486),fill=C['line'])
    text(d,48,293,'CHATS / 对话',13,C['soft'])
    for i,name in enumerate(['Siberian','Tuxedo','Sheltie']):
        y=328+i*43
        if i==(1 if 'awaiting' in poses else 0):rr(d,(41,y-8,196,y+26),C['selected'],r=7)
        color=C['amber'] if poses[i]=='awaiting' else C['green'] if poses[i]=='thinking' else C['soft']
        d.ellipse((49,y+4,55,y+10),fill=color);text(d,66,y,name,15,C['white'])
    text(d,234,290,'A little company for every task.',22,C['white'])
    subword='subagent' if subs==1 else 'subagents';jobword='job' if jobs==1 else 'jobs'
    text(d,235,322,f'{active} active chats / 活跃对话   ·   {subs} {subword} / 子代理   ·   {jobs} {jobword} / 后台任务',13,C['soft'])
    labels=['Build UI / 构建界面','Review changes / 审查代码','Run checks / 执行检查']
    for i,label in enumerate(labels):
        y=351+i*39;rr(d,(231,y,948,y+31),C['card'],r=6)
        text(d,244,y+8,label,14,C['white'])
        p=poses[i]
        status='Needs your reply / 等待回复' if p=='awaiting' else 'Working / 工作中' if p=='thinking' else 'Taking a break / 休息中'
        color=C['amber'] if p=='awaiting' else C['green'] if p=='thinking' else C['soft']
        text(d,701,y+8,status,13,color)
    layer=Image.new('RGBA',(W,H));xs=[]
    for slot,pose in enumerate(poses):xs.append(draw_main(layer,slot,pose,t))
    for slot,role in minis:draw_mini(layer,slot,role,t)
    # Native panels clip at the ledge; retain the sleeping/lying -2pt offset.
    im.paste(layer.crop((0,0,W,FLOOR)),(0,0),layer.crop((0,0,W,FLOOR)))
    d=ImageDraw.Draw(im);rr(d,(30,507,970,572),'#ffffff',r=12)
    text(d,50,519,'Book = working / 读书 = 工作中     ? = needs you / 问号 = 等待回复',15)
    text(d,50,547,'... = subagent / 子代理     * = background job / 后台任务',15)
    text(d,32,588,'Actual shipped sprites · Illustrated loop, not a screen recording / 实际素材模拟演示，非屏幕录制',12,C['muted'])
    return im,{'t':round(t,2),'poses':poses,'minis':[r for _,r in minis],'x':xs}

# One global palette: preserve original sprite colors and avoid GIF palette flicker.
colors=[]
def add(c):
    if c not in colors and len(colors)<256:colors.append(c)
for sheet in SHEETS+MINIS:
    for pixel in sorted(set(getattr(sheet,'get_flattened_data',sheet.getdata)())):
        if pixel[3]:add(pixel[:3])
for value in list(C.values())+['#e7e1f4','#6e6889','#fb746c','#edc45f','#63c999','#ffffff','#383838','#2e2e2e']:
    add(tuple(bytes.fromhex(value[1:])))
samples=[render(t)[0] for t in (0,4.8,8.5,11.0)]
contact=Image.new('RGB',(W,H*len(samples)))
for i,im in enumerate(samples):contact.paste(im,(0,H*i))
p=contact.quantize(colors=128).getpalette()
for i in range(0,len(p),3):add(tuple(p[i:i+3]))
colors += [(0,0,0)]*(256-len(colors))
palette=Image.new('P',(1,1));palette.putpalette([v for c in colors for v in c])
frames=[];timeline=[]
for i in range(COUNT):
    im,meta=render(i*FRAME_MS/1000);timeline.append(meta)
    frames.append(im.quantize(palette=palette,dither=Image.Dither.NONE))
frames[0].save(OUT/'pets-demo.gif',save_all=True,append_images=frames[1:],duration=FRAME_MS,loop=0,optimize=True,disposal=1)
for name,t in [('working',0),('waiting',6.3),('resting',8.5),('walking',11.0)]:render(t)[0].save(CHECKS/f'{name}.png')
with Image.open(OUT/'pets-demo.gif') as gif:
    duration=0
    for i in range(gif.n_frames):gif.seek(i);duration+=gif.info['duration']
    assert gif.size==(W,H) and duration==COUNT*FRAME_MS and gif.info.get('loop')==0
    frame_count=gif.n_frames
assert {r for s in timeline for r in s['minis']}=={'subagent','job'}
assert {'walk','sleep','thinking','awaiting','lying','stretch'} <= {p for s in timeline for p in s['poses']}
walk_x=[s['x'][0] for s in timeline if s['poses'][0]=='walk'];assert max(walk_x)-min(walk_x)>45
manifest={'canvas':[W,H],'durationMs':duration,'frames':frame_count,'bytes':(OUT/'pets-demo.gif').stat().st_size,'source':'Shipped Codex sprite atlases; pixel bubble glyphs match native CatView; mock UI only','timeline':timeline}
(CHECKS/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({k:v for k,v in manifest.items() if k!='timeline'}))
