// gallery.js
(function (global) {
  const EXT_ORDER = ['avif','webp','jpg','jpeg','png','AVIF','WEBP','JPG','JPEG','PNG'];

  function findFirstAvailable(basePath, baseName) {
    return new Promise((resolve) => {
      let i = 0, done = false;
      const tryNext = () => {
        if (done || i >= EXT_ORDER.length) return resolve(null);
        const ext = EXT_ORDER[i++];
        const url = basePath + baseName + '.' + ext;
        const img = new Image();
        img.decoding = 'async';
        img.onload = () => { if (!done) { done = true; resolve({ url, ext }); } };
        img.onerror = tryNext;
        img.src = url;
      };
      tryNext();
    });
  }

  async function buildPersonGallery(opts) {
    const {
      prefix,                 // 'A' или 'Z'
      basePath = '../assets/',// путь к assets из текущей страницы
      mainSelector,           // селектор контейнера для главной картинки (index 0)
      gallerySelector,        // селектор контейнера для галереи
      galleryFrom = 1,        // с какого номера брать
      galleryTo = 9,          // по какой номер включительно
      altBase = ''            // базовый alt-текст
    } = opts || {};

    if (!prefix) { console.warn('buildPersonGallery: prefix обязателен'); return; }

    // Главная картинка: prefix0
    if (mainSelector) {
      const host = document.querySelector(mainSelector);
      if (host) {
        const hit0 = await findFirstAvailable(basePath, prefix + '0');
        if (hit0) {
          const img = document.createElement('img');
          img.src = hit0.url;
          img.alt = altBase || (prefix + '0');
          img.decoding = 'async';
          img.fetchPriority = 'high';
          img.loading = 'eager';
          img.style.maxWidth = '100%';
          img.style.borderRadius = '12px';
          host.innerHTML = '';
          host.appendChild(img);
        } else {
          // host.style.display = 'none'; // если нужно скрывать, когда нет файла 0
        }
      }
    }

    // Галерея: prefix1..prefix9
    if (gallerySelector) {
      const grid = document.querySelector(gallerySelector);
      if (grid) {
        let added = 0;
        for (let i = galleryFrom; i <= galleryTo; i++) {
          const hit = await findFirstAvailable(basePath, prefix + i);
          if (!hit) continue;
          const fig = document.createElement('figure');
          fig.className = 'gallery-item';
          const img = document.createElement('img');
          img.src = hit.url;
          img.alt = altBase ? `${altBase} ${i}` : (prefix + i);
          img.decoding = 'async';
          img.loading = 'lazy';
          img.fetchPriority = 'low';
          img.style.width = '100%';
          img.style.display = 'block';
          fig.appendChild(img);
          grid.appendChild(fig);
          added++;
        }
        if (added === 0) {
          // grid.style.display = 'none'; // при желании скрыть пустую галерею
        }
      }
    }
  }

  // Глобально
  global.buildPersonGallery = buildPersonGallery;
})(window);