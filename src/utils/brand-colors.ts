/**
 * Extract dominant brand color from an uploaded logo image.
 * Uses canvas sampling with hue clustering.
 */

function pixelToHSL(r: number, g: number, b: number): { h: number; s: number; l: number } {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  const l = (max + min) / 2;
  if (max === min) return { h: 0, s: 0, l };
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h = 0;
  if (max === r) h = ((g - b) / d + (g < b ? 6 : 0)) / 6;
  else if (max === g) h = ((b - r) / d + 2) / 6;
  else h = ((r - g) / d + 4) / 6;
  return { h: h * 360, s, l };
}

function isNeutralColor(r: number, g: number, b: number): boolean {
  const { s, l } = pixelToHSL(r, g, b);
  return s < 0.1 || l < 0.15 || l > 0.85;
}

function rgbToHex(r: number, g: number, b: number): string {
  return '#' + [r, g, b].map(c => Math.round(c).toString(16).padStart(2, '0')).join('');
}

export function extractBrandColor(imageDataUrl: string): Promise<string | null> {
  return new Promise((resolve) => {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = () => {
      const canvas = document.createElement('canvas');
      const size = 50;
      canvas.width = size;
      canvas.height = size;
      const ctx = canvas.getContext('2d');
      if (!ctx) { resolve(null); return; }
      ctx.drawImage(img, 0, 0, size, size);
      
      const data = ctx.getImageData(0, 0, size, size).data;
      const colorCounts = new Map<string, { count: number; r: number; g: number; b: number }>();
      
      for (let i = 0; i < data.length; i += 16) { // sample every 4th pixel
        const r = data[i], g = data[i + 1], b = data[i + 2], a = data[i + 3];
        if (a < 128) continue; // skip transparent
        if (isNeutralColor(r, g, b)) continue; // skip white/black/gray
        
        const hex = rgbToHex(r, g, b);
        const existing = colorCounts.get(hex);
        if (existing) {
          existing.count++;
        } else {
          colorCounts.set(hex, { count: 1, r, g, b });
        }
      }
      
      if (colorCounts.size === 0) { resolve(null); return; }
      
      // Find the most frequent color
      let topColor: { count: number; r: number; g: number; b: number } | null = null;
      for (const entry of colorCounts.values()) {
        if (!topColor || entry.count > topColor.count) {
          topColor = entry;
        }
      }
      
      resolve(topColor ? rgbToHex(topColor.r, topColor.g, topColor.b) : null);
    };
    img.onerror = () => resolve(null);
    img.src = imageDataUrl;
  });
}