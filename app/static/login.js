(() => {
  const form = document.querySelector('#login-form');
  const password = document.querySelector('#login-password');
  const toggle = document.querySelector('.password-toggle');
  const clientError = document.querySelector('#client-error');

  if (toggle && password) {
    toggle.addEventListener('click', () => {
      const showing = password.type === 'text';
      password.type = showing ? 'password' : 'text';
      toggle.classList.toggle('is-visible', !showing);
      toggle.setAttribute('aria-pressed', String(!showing));
      toggle.setAttribute('aria-label', showing ? '显示密码' : '隐藏密码');
      password.focus({ preventScroll: true });
      const end = password.value.length;
      password.setSelectionRange(end, end);
    });
  }

  if (form) {
    form.addEventListener('submit', event => {
      const missing = [...form.querySelectorAll('input[required]')].filter(input => !input.value.trim());
      if (!missing.length) return;
      event.preventDefault();
      clientError.hidden = false;
      missing.forEach(input => input.setAttribute('aria-invalid', 'true'));
      missing[0].focus();
    });

    form.addEventListener('input', event => {
      if (event.target.matches('input')) event.target.removeAttribute('aria-invalid');
      if ([...form.querySelectorAll('input[required]')].every(input => input.value.trim())) {
        clientError.hidden = true;
      }
    });
  }
})();
