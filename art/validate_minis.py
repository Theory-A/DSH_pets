from pathlib import Path
import json,hashlib
from PIL import Image
import numpy as np
root=Path(__file__).resolve().parent
original_hashes={
 'silver-siberian':'7e83fb0839d74849c12bf26899a7b1b74d5c23a6147364a59fb4dffbf91e060b',
 'tuxedo':'006b6b4e0bf093f42418485e7ebaf03d3a39601da9535ee625baf7e3d55e2b3a',
 'sheltie':'86cd8dd026c66372d3ab8b2a564e911ca013a42afcc69764b5b9c8b2d05029b0',
}
manifest=json.loads((root/'mini-sprites.json').read_text())
assert len(manifest)==3
for breed,digest in original_hashes.items():
 assert hashlib.sha256((root/f'{breed}-colony.png').read_bytes()).hexdigest()==digest,('main art changed',breed)
 image=Image.open(root/f'{breed}-mini.png');a=np.array(image)
 assert image.mode=='RGBA' and image.size==(96,40)
 assert set(np.unique(a[:,:,3]).tolist())=={0,255}
 assert len(np.unique(a[:,:,:3][a[:,:,3]>0],axis=0))<=48
 for i in range(2):
  f=a[:,i*48:(i+1)*48];ys,xs=np.nonzero(f[:,:,3]);c=f[:,:,:3].astype(int)
  assert len(xs)>300 and ys.max()==39 and ys.min()>=12
  assert xs.min()>0 and xs.max()<47
  assert not np.any((f[:,:,3]>0)&(c[:,:,0]>c[:,:,1]+55)&(c[:,:,2]>c[:,:,1]+55))
 record=next(r for r in manifest if r['breed']==breed)
 assert all(f['removedBubblePixels']>=200 and f['sourceIndex'] in (6,7) for f in record['frames'])
 print('PASS',breed,'two registered mini bodies, empty bubble area, unchanged original atlas')
