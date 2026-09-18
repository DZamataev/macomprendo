const words = ['code', 'rephrase', 'summarize', 'refine', 'write', 'reply', 'translate'];

export function startHeadline(doc, env) {
  const word = doc.querySelector('#rotating-action');
  const button = doc.querySelector('.motion-toggle');
  if (!word || !button) return;
  const motion = env.matchMedia('(prefers-reduced-motion: reduce)');
  let index = 0;
  let paused = false;
  let timer;
  const sync = () => {
    env.clearInterval(timer);
    word.classList.remove('is-glitching');
    button.hidden = motion.matches;
    button.textContent = paused ? 'Resume word animation' : 'Pause word animation';
    button.setAttribute('aria-pressed', String(paused));
    if (motion.matches || paused || doc.hidden) return;
    timer = env.setInterval(() => {
      index = (index + 1) % words.length;
      word.textContent = words[index];
      word.dataset.word = words[index];
      word.classList.add('is-glitching');
    }, 2800);
  };
  word.addEventListener('animationend', () => word.classList.remove('is-glitching'));
  button.addEventListener('click', () => { paused = !paused; sync(); });
  motion.addEventListener('change', sync);
  doc.addEventListener('visibilitychange', sync);
  sync();
}

if (typeof document !== 'undefined') startHeadline(document, window);
