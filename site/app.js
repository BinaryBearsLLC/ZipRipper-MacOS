'use strict';
const features = {
  recovery: ['01 / RECOVER', 'A way back in.', 'Choose an archive or PDF. Use a wordlist, remembered pattern or a focused combination search.'],
  sessions: ['02 / RESUME', 'Pick up where you left off.', 'Pause safely and keep your progress. Your sessions and recovered passwords stay on your Mac.'],
  engine: ['03 / COMPUTE', 'Ready. No setup required.', 'Bundled recovery engines, native Metal support and a saved benchmark. Automatic compares CPU and GPU on your file.'],
  about: ['04 / EXPLORE', 'Everything in one place.', 'Find wordlist resources, project credits and licenses. Built for files you own or have permission to recover.']
};
const panel = document.querySelector('.feature');
const buttons = [...document.querySelectorAll('.hotspot')];
function show(button) {
  const [number, title, text] = features[button.dataset.section];
  panel.querySelector('.feature-number').textContent = number;
  panel.querySelector('h2').textContent = title;
  panel.querySelector('p').textContent = text;
  panel.classList.add('visible');
  buttons.forEach(item => item.setAttribute('aria-expanded', String(item === button)));
}
function hide() {
  panel.classList.remove('visible');
  buttons.forEach(button => button.setAttribute('aria-expanded', 'false'));
  // Do not leave a stale explanation in the accessibility tree.
  panel.querySelector('h2').textContent = '';
  panel.querySelector('p').textContent = '';
  panel.querySelector('.feature-number').textContent = '';
}
buttons.forEach(button => {
  button.addEventListener('pointerenter', event => { if(event.pointerType !== 'touch') show(button); });
  button.addEventListener('pointerleave', () => { if(document.activeElement !== button) hide(); });
  button.addEventListener('focus', () => show(button));
  button.addEventListener('blur', hide);
  button.addEventListener('click', () => show(button));
});
document.addEventListener('keydown', event => { if(event.key === 'Escape') { document.activeElement?.blur(); hide(); } });
