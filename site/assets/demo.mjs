const rough = 'Use sequel light to save my notes.';
const clean = 'Use SQLite to save my notes.';
const type = (text, elapsed) => text.slice(0, Math.max(0, Math.ceil(text.length * elapsed / 2600)));

const cycleDuration = 24000;

export function demoFrame(ms) {
  ms %= cycleDuration;
  if (ms < 3000) return { phase: 'dictating', text: type(rough, ms), caption: 'Lost in transcription.', agent: 'Waiting for your instructions' };
  if (ms < 4500) return { phase: 'sending', text: rough, caption: 'Sent without a second look.', agent: 'A sequel… to a lamp?' };
  if (ms < 6000) return { phase: 'confused', text: rough, caption: 'That is not what you meant.', agent: 'I… what?' };
  if (ms < 8000) return { phase: 'dead', text: rough, caption: 'Well, that went badly.', agent: 'Agent.exe has left the chat.' };
  if (ms < 10000) return { phase: 'crossed', text: rough, caption: 'Let’s try that again.', agent: 'Agent.exe has left the chat.' };
  if (ms < 13000) return { phase: 'retry', text: type(rough, ms - 10000), caption: 'Same voice. Refined text.', agent: 'Waiting for your instructions' };
  if (ms < 16000) return { phase: 'correcting', text: clean, replacement: 'SQLite'.slice(0, Math.max(0, Math.ceil((ms - 13400) / 200))), caption: 'Refine the text. Review the result.', agent: 'Waiting for your instructions' };
  if (ms < 19000) return { phase: 'understood', text: clean, replacement: 'SQLite', caption: 'Now we understand each other.', agent: 'SQLite connected. Notes saved.' };
  return { phase: 'heart', text: clean, caption: '', agent: 'SQLite connected. Notes saved.' };
}

export function startDemo(doc, env) {
  const root = doc.querySelector('.voice-demo');
  if (!root) return;
  const button = root.querySelector('.demo-toggle');
  const replay = root.querySelector('.demo-replay');
  const motion = env.matchMedia('(prefers-reduced-motion: reduce)');
  let elapsed = 0;
  let visible = false;
  let paused = false;
  let last = null;
  let request;
  function render() {
    const frame = demoFrame(motion.matches ? 17000 : elapsed);
    root.dataset.phase = frame.phase;
    root.querySelector('.demo-transcript').textContent = frame.text || '…';
    root.querySelector('.demo-transcript').hidden = frame.replacement !== undefined;
    root.querySelector('.demo-correction').hidden = frame.replacement === undefined;
    root.querySelector('.correction-word').textContent = frame.replacement ?? '';
    root.querySelector('.demo-caption').textContent = frame.caption;
    root.querySelector('.agent-message').textContent = frame.agent;
    root.querySelector('.demo-progress').style.width = `${Math.min(100, elapsed / cycleDuration * 100)}%`;
    button.textContent = paused ? 'Play' : 'Pause';
    button.setAttribute('aria-pressed', String(paused));
  }
  function tick(time) {
    if (last !== null) elapsed = (elapsed + Math.min(time - last, 100)) % cycleDuration;
    last = time;
    render();
    request = env.requestAnimationFrame(tick);
  }
  function sync() {
    env.cancelAnimationFrame(request);
    last = null;
    button.hidden = motion.matches;
    replay.hidden = motion.matches;
    root.dataset.running = String(visible && !paused && !doc.hidden && !motion.matches);
    render();
    if (root.dataset.running === 'true') request = env.requestAnimationFrame(tick);
  }
  button.addEventListener('click', () => { paused = !paused; sync(); });
  replay.addEventListener('click', () => { elapsed = 0; paused = false; sync(); });
  doc.addEventListener('visibilitychange', sync);
  motion.addEventListener('change', sync);
  if (env.IntersectionObserver) {
    new env.IntersectionObserver(entries => { visible = entries[0].isIntersecting; sync(); }, { threshold: .25 }).observe(root);
  } else visible = true;
  sync();
}
if (typeof document !== 'undefined') startDemo(document, window);
