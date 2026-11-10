// theme: follows the system until you choose; the choice stays in this browser only
(function(){
  const root=document.documentElement;
  let saved=null; try{saved=localStorage.getItem('theme')}catch(e){}
  if(saved==='light'||saved==='dark') root.setAttribute('data-theme',saved);
  const current=()=>root.getAttribute('data-theme')||(matchMedia('(prefers-color-scheme: light)').matches?'light':'dark');
  function swapImages(){
    const t=current();
    document.querySelectorAll('img[data-light]').forEach(img=>{
      const pic=img.parentElement;
      if(pic&&pic.tagName==='PICTURE') pic.querySelectorAll('source').forEach(s=>s.remove());
      img.src=img.dataset[t];
    });
  }
  if(root.hasAttribute('data-theme')) swapImages();
  document.querySelectorAll('.theme').forEach(btn=>btn.addEventListener('click',()=>{
    const next=current()==='light'?'dark':'light';
    root.setAttribute('data-theme',next);
    try{localStorage.setItem('theme',next)}catch(e){}
    swapImages();
  }));
})();
// copy buttons, with a fallback and a message for screen readers
(function(){
  const live=document.getElementById('copied');
  function fallback(text){const t=document.createElement('textarea');t.value=text;t.setAttribute('readonly','');t.style.position='fixed';t.style.opacity='0';document.body.appendChild(t);t.select();let ok=false;try{ok=document.execCommand('copy')}catch(e){}t.remove();return ok}
  document.querySelectorAll('[data-copy]').forEach(b=>b.addEventListener('click',async()=>{
    const text=b.dataset.copy; let ok=false;
    try{await navigator.clipboard.writeText(text);ok=true}catch(e){ok=fallback(text)}
    b.textContent=ok?'Copied':'Select to copy';
    if(live) live.textContent=ok?'Copied to the clipboard':'Copying failed; select the text instead';
    setTimeout(()=>{b.textContent='Copy'},1600);
  }));
})();
// install tabs
(function(){
  const tabs=[...document.querySelectorAll('.tabs [role=tab]')];
  function select(t){tabs.forEach(x=>{const on=x===t;x.setAttribute('aria-selected',on);x.tabIndex=on?0:-1;document.getElementById(x.getAttribute('aria-controls')).hidden=!on})}
  tabs.forEach((t,i)=>{
    t.addEventListener('click',()=>select(t));
    t.addEventListener('keydown',e=>{const d=e.key==='ArrowRight'?1:e.key==='ArrowLeft'?-1:0;const n=d?tabs[(i+d+tabs.length)%tabs.length]:e.key==='Home'?tabs[0]:e.key==='End'?tabs[tabs.length-1]:null;if(n){select(n);n.focus();e.preventDefault()}});
  });
})();
// mobile menu: close after a link is chosen
document.querySelectorAll('.menu .panel a').forEach(a=>a.addEventListener('click',()=>a.closest('details').removeAttribute('open')));
// sticky download on phones, once the hero button is out of view and before the final call to action
(function(){
  const s=document.getElementById('sticky'), dl=document.getElementById('dl'), fin=document.querySelector('.final');
  if(!s||!dl||!fin||!('IntersectionObserver' in window)) return;
  let heroOut=false, finalIn=false;
  const upd=()=>s.classList.toggle('show',heroOut&&!finalIn);
  new IntersectionObserver(es=>{heroOut=!es[0].isIntersecting&&es[0].boundingClientRect.top<0;upd()}).observe(dl);
  new IntersectionObserver(es=>{finalIn=es[0].isIntersecting;upd()}).observe(fin);
})();
// push simulation: 14 pushes, 3 connected projects, about 6 cents a build
(function(){
  const A=document.getElementById('laneA'),B=document.getElementById('laneB');
  const bA=document.getElementById('billA'),bB=document.getElementById('billB');
  const cA=document.getElementById('costA'),cB=document.getElementById('costB');
  const ctl=document.getElementById('animctl');
  const reduce=matchMedia('(prefers-reduced-motion: reduce)').matches;
  const msgs=['fix typo','bump deps','wip','tweak css','add test','readme','refactor','fix lint','agent: step 3','agent: fix test','agent: rename','copy edits','try again','final'];
  const PER=0.06, PROJECTS=3, PUSHES=14;
  let n=0,a=0,paused=false,timer=null,started=false;
  const money=v=>'≈ $'+v.toFixed(2)+' today';
  function chip(el,cls,txt){const s=document.createElement('span');s.className='tick '+cls;s.textContent=txt;el.appendChild(s)}
  function reset(){A.innerHTML='';B.innerHTML='';n=0;a=0;bA.textContent=0;bB.textContent=0;cA.textContent=money(0);cB.textContent=money(0)}
  function finish(){B.querySelectorAll('.wait').forEach(e=>e.remove());chip(B,'ok','✓ one deploy · '+PUSHES+' commits · '+PROJECTS+' builds');bB.textContent=PROJECTS;cB.textContent=money(PROJECTS*PER)}
  function step(){
    if(paused) return;
    if(n>=PUSHES){finish();timer=setTimeout(()=>{if(paused)return;reset();step()},3200);return}
    const m=msgs[n%msgs.length]; n++;
    a+=PROJECTS; chip(A,'',`build ×${PROJECTS} · ${m}`); bA.textContent=a; cA.textContent=money(a*PER);
    chip(B,'wait',`waiting · ${m}`);
    timer=setTimeout(step,520);
  }
  function still(){reset();for(let i=0;i<PUSHES;i++)chip(A,'',`build ×${PROJECTS}`);a=PUSHES*PROJECTS;bA.textContent=a;cA.textContent=money(a*PER);finish()}
  ctl.addEventListener('click',()=>{
    paused=!paused; ctl.setAttribute('aria-pressed',paused); ctl.textContent=paused?'Play animation':'Pause animation';
    if(!paused&&started){clearTimeout(timer);if(n>=PUSHES)reset();step()}
  });
  if(reduce){still();ctl.hidden=true;return}
  // a hidden tab pauses the loop; it goes on when the tab is visible again (unless paused by hand)
  document.addEventListener('visibilitychange',()=>{
    if(document.hidden){clearTimeout(timer);timer=null}
    else if(started&&!paused&&!timer){if(n>=PUSHES)reset();step()}
  });
  const io=new IntersectionObserver(es=>{if(es[0].isIntersecting){io.disconnect();started=true;step()}},{threshold:.3});
  io.observe(A);
})();
