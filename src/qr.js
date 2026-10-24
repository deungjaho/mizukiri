import qrcode from 'qrcode-generator';

/**
 * 生成与 server.el 视觉风格一致的和风配色 SVG QR 码 Data URI
 * @param {string} url 
 * @param {number} margin 静区边距模块数（默认 2 个模块）
 * @returns {string|null}
 */
export function makeQrDataUrl(url, margin = 2) {
  try {
    const qr = qrcode(0, 'M');
    qr.addData(url);
    qr.make();
    const count = qr.getModuleCount();
    const totalSize = count + margin * 2;

    let rects = '';
    for (let row = 0; row < count; row++) {
      for (let col = 0; col < count; col++) {
        if (qr.isDark(row, col)) {
          rects += `<rect x="${col + margin}" y="${row + margin}" width="1" height="1" fill="#2c2416"/>`;
        }
      }
    }

    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${totalSize} ${totalSize}" width="256" height="256" shape-rendering="crispEdges"><rect width="${totalSize}" height="${totalSize}" fill="#fffef9"/>${rects}</svg>`;
    // 使用 Web 标准的 encodeURIComponent，彻底摆脱对 Node.js Buffer 的依赖
    return `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`;
  } catch (err) {
    console.error('[!] QR generation error:', err);
    return null;
  }
}
