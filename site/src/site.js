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
