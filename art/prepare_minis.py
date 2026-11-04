"""Derive half-size reading sprites from existing Codex artwork; no new artwork synthesis.
Remove disconnected thought-cloud components so native UI can draw a legible role glyph.
"""
from pathlib import Path
from collections import deque
import json
import numpy as np
from PIL import Image
ROOT = Path(__file__).resolve().parent
BREEDS = ('silver-siberian', 'tuxedo', 'sheltie')

def components(mask):
    seen=np.zeros(mask.shape,bool); result=[]
    for y,x in zip(*np.nonzero(mask)):
        if seen[y,x]: continue
        queue=deque([(int(y),int(x))]); seen[y,x]=True; points=[]
        while queue:
            yy,xx=queue.popleft(); points.append((yy,xx))
            for dy in (-1,0,1):
                for dx in (-1,0,1):
                    ny,nx=yy+dy,xx+dx
                    if 0<=ny<mask.shape[0] and 0<=nx<mask.shape[1] and mask[ny,nx] and not seen[ny,nx]:
                        seen[ny,nx]=True;queue.append((ny,nx))
        result.append(points)
    return sorted(result,key=len,reverse=True)

records=[]
for breed in BREEDS:
    source=ROOT/f'{breed}-colony.png'
    image=Image.open(source).convert('RGBA')
    sheet=Image.new('RGBA',(96,40));frames=[]
    for out_index,source_index in enumerate((6,7)):
        x,y=(source_index%4)*96,(source_index//4)*80
        a=np.array(image.crop((x,y,x+96,y+80))).copy()
        parts=components(a[:,:,3]>0);body=parts[0]
        assert len(body)>1000,(breed,'unexpected disconnected body')
        top=min(y for y,x in body)
        keep=np.zeros((80,96),bool)
        for points in parts:
            # Keep the full connected body and any tiny lower whisker fragments.
            # Clouds and connector dots are disconnected and above this lower band.
            if points is body or (len(points)<=8 and min(y for y,x in points)>=top+14):
                yy,xx=zip(*points);keep[yy,xx]=True
        removed=int(np.count_nonzero(a[:,:,3]))-int(keep.sum())
        assert removed>=200,(breed,'thought cloud was not removed')
        a[~keep]=0
        mini=Image.fromarray(a).resize((48,40),Image.Resampling.NEAREST)
        # Nearest sampling can lose a one-pixel foot tip; register the resulting
        # silhouette rather than allowing a one-pixel ground gap in a book frame.
        offset=40-mini.getbbox()[3]
        if offset:
            aligned=Image.new('RGBA',(48,40));aligned.paste(mini,(0,offset));mini=aligned
        m=np.array(mini); yy,xx=np.nonzero(m[:,:,3]);bounds=mini.getbbox()
        assert set(np.unique(m[:,:,3]).tolist())=={0,255}
        assert len(xx)>300 and yy.max()==39 and yy.min()>=12, (breed, source_index, len(xx), bounds)
        assert xx.min()>0 and xx.max()<47
        sheet.paste(mini,(out_index*48,0))
        frames.append({'sourceIndex':source_index,'index':out_index,'bodyPixels':int(keep.sum()),'removedBubblePixels':removed,'bbox':bounds,'bodyTopSource':top,'postResizeOffsetY':offset})
    output=ROOT/f'{breed}-mini.png';sheet.save(output,optimize=True)
    records.append({'breed':breed,'source':source.name,'output':output.name,'size':[96,40],'cell':[48,40],'baselineY':39,'frames':frames,'bytes':output.stat().st_size})
(ROOT/'mini-sprites.json').write_text(json.dumps(records,indent=2)+'\n')
print(json.dumps(records,indent=2))
