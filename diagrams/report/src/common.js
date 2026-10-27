// arrows: [fromId, fromSide, toId, toSide, cls, label, labelPos(0..1), opts]
function pt(el, side, root){const r=el.getBoundingClientRect(), o=root.getBoundingClientRect();
  const x=r.left-o.left, y=r.top-o.top;
  return {l:[x,y+r.height/2],r:[x+r.width,y+r.height/2],t:[x+r.width/2,y],b:[x+r.width/2,y+r.height]}[side[0]]
    .map((v,i)=>v+(side.length>1? (i==0&&'tb'.includes(side[0])||i==1&&'lr'.includes(side[0]) ? +side.slice(1):0):0));}
function draw(arrows){
  const root=document.getElementById('fig'); const svg=document.getElementById('arrows');
  const ns='http://www.w3.org/2000/svg';
  svg.setAttribute('width',root.scrollWidth); svg.setAttribute('height',root.scrollHeight);
  for(const [a,sa,b,sb,cls,label,lp,mid] of arrows){
    const p=pt(document.getElementById(a),sa,root), q=pt(document.getElementById(b),sb,root);
    let d; const h=s=>'lr'.includes(s[0]);
    if(h(sa)&&h(sb)){const mx= mid!=null? mid : (p[0]+q[0])/2; d=`M${p[0]} ${p[1]} H${mx} V${q[1]} H${q[0]}`;}
    else if(!h(sa)&&!h(sb)){const my= mid!=null? mid : (p[1]+q[1])/2; d=`M${p[0]} ${p[1]} V${my} H${q[0]} V${q[1]}`;}
    else if(h(sa)){d=`M${p[0]} ${p[1]} H${q[0]} V${q[1]}`;} else {d=`M${p[0]} ${p[1]} V${q[1]} H${q[0]}`;}
    const path=document.createElementNS(ns,'path'); path.setAttribute('d',d); path.setAttribute('class','a '+cls);
    path.setAttribute('marker-end',`url(#m-${cls.split(' ')[0]})`); svg.appendChild(path);
    if(label){const L=path.getTotalLength(), P=path.getPointAtLength(L*(lp??0.5));
      const t=document.createElement('div'); t.className='lbl '+cls; t.textContent=label;
      t.style.left=P.x+'px'; t.style.top=P.y+'px'; root.appendChild(t);}
  }
}
