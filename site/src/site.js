// 首页翻页演示（← → 和按钮）、手机访客提示
(() => {
  const root = document.documentElement;
  const phone = /iPhone|Android|Mobile/i.test(navigator.userAgent) && !/iPad|Macintosh/i.test(navigator.userAgent);
  if (phone) root.classList.add('is-phone');
  const copy = document.querySelector('.copy');
  if (copy) copy.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(copy.dataset.url);
      copy.textContent = copy.dataset.done;
    } catch {
      copy.textContent = copy.dataset.url;
    }
  });

  const frame = document.getElementById('frame');
  if (!frame) return;
  const total = Number(frame.dataset.total), base = frame.dataset.base, altText = frame.dataset.alt;
  const count = document.getElementById('count');
  const imgs = [frame.querySelector('img')];
  let i = 0;
  const get = n => {
    if (!imgs[n]) {
      const im = new Image(1440, 900);
      im.src = `${base}browse-${String(n + 1).padStart(2, '0')}.webp`;
      im.alt = altText.replace('{n}', n + 1);
      im.decoding = 'async';
      frame.appendChild(im);
      imgs[n] = im;
    }
    return imgs[n];
  };
  const go = step => {
    const next = (i + step + total) % total, im = get(next);
    const show = () => {
      imgs[i].classList.remove('on'); im.classList.add('on'); i = next;
      count.textContent = `${i + 1} / ${total}`;
      get((i + step + total) % total);
    };
    im.complete ? show() : im.addEventListener('load', show, { once: true });
  };
  const flash = step => {
    const b = document.querySelector(`.keys button[data-step="${step}"]`);
    b.classList.add('hit');
    setTimeout(() => b.classList.remove('hit'), 140);
  };
  document.addEventListener('keydown', e => {
    if (e.metaKey || e.ctrlKey || e.altKey || e.target.closest('input, textarea')) return;
    if (e.key === 'ArrowRight') { e.preventDefault(); flash(1); go(1); }
    if (e.key === 'ArrowLeft') { e.preventDefault(); flash(-1); go(-1); }
  });
  document.querySelectorAll('.keys button').forEach(b => b.addEventListener('click', () => go(Number(b.dataset.step))));
  window.addEventListener('load', () => { get(1); get(total - 1); });
})();

// GA4 埋点：下载、购买、GitHub、找回激活码、切换语言、手机复制网址、首页翻页演示。gtag 没加载（被拦截、国内网络）时什么都不做
(() => {
  const send = (name, params = {}) => { if (typeof window.gtag === 'function') window.gtag('event', name, params); };
  const where = el => (el.closest('[id]') || {}).id || (el.closest('header, footer, section, main') || {}).tagName?.toLowerCase() || 'page';
  document.addEventListener('click', e => {
    const a = e.target.closest('a');
    if (a) {
      const href = a.getAttribute('href') || '';
      if (/\/download\/Flipic\.dmg$|\/releases\/(latest\/)?download\//.test(href)) send('download_click', { link_location: where(a), link_url: href });
      else if (href.startsWith('https://buy.stripe.com')) send('begin_checkout', { currency: a.dataset.currency, value: Number(a.dataset.value), link_location: where(a), items: [{ item_id: 'flipic_pro', item_name: 'Flipic Pro' }] });
      else if (href.startsWith('https://github.com/xmasdong/flipic')) send('github_click', { link_location: where(a), link_url: href });
      else if (href.includes('pay.flipic.app/recover')) send('recover_key_click', { link_location: where(a) });
      else if (a.classList.contains('lang')) send('language_switch', { to: a.getAttribute('hreflang') });
    }
    if (e.target.closest('.copy')) send('phone_copy_url');
  });
  let demo = false;
  const played = how => { if (!demo) { demo = true; send('demo_flip', { method: how }); } };
  if (document.getElementById('frame')) {
    document.addEventListener('keydown', e => { if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') played('keyboard'); });
    document.querySelectorAll('.keys button').forEach(b => b.addEventListener('click', () => played('button')));
  }
})();
