import { useState, useCallback, useRef } from 'react';
import type { SignatureData, SignatureStyle, CustomField } from '../types';
import { DEFAULT_SIGNATURE, DEFAULT_STYLE, ACCENT_COLORS, EMAIL_FONTS, TEMPLATES, TEMPLATE_LABELS } from '../types';
import { SignaturePreview } from './SignaturePreview';
import { toPng } from 'html-to-image';
import { Mail, Phone, Smartphone, Globe, MapPin, Link, Plus, Trash2, Upload, Download, Image, QrCode, ChevronRight, ChevronLeft, Eye, Code, User, Building2, Palette, Copy, Check, FileText, MessageCircle } from 'lucide-react';
import { phoneFormatHint } from '../utils/phone';

type Step = 'details' | 'images' | 'social' | 'template' | 'design';
const STEPS: Step[] = ['details', 'images', 'social', 'template', 'design'];
const STEP_LABELS: Record<Step, string> = {
  details: 'Details',
  images: 'Bilder',
  social: 'Social',
  template: 'Vorlage',
  design: 'Design',
};
const STEP_ICONS: Record<Step, React.ReactNode> = {
  details: <User size={14} />,
  images: <Image size={14} />,
  social: <Globe size={14} />,
  template: <Mail size={14} />,
  design: <Palette size={14} />,
};

export function SignatureEditor() {
  const [data, setData] = useState<SignatureData>(DEFAULT_SIGNATURE);
  const [style, setStyle] = useState<SignatureStyle>(DEFAULT_STYLE);
  const [step, setStep] = useState<Step>('details');
  const [copied, setCopied] = useState<string | null>(null);
  const [exportMode, setExportMode] = useState<'visual' | 'html'>('visual');
  const [showHowTo, setShowHowTo] = useState(false);
  const previewRef = useRef<HTMLDivElement>(null);

  const updateData = (field: keyof SignatureData, value: string | SignatureData['customFields']) => {
    setData(prev => ({ ...prev, [field]: value }));
  };

  const updateStyle = (field: keyof SignatureStyle, value: string | number | boolean) => {
    setStyle(prev => ({ ...prev, [field]: value }));
  };

  const addCustomField = () => {
    const field: CustomField = { id: crypto.randomUUID(), label: '', value: '', type: 'text' };
    setData(prev => ({ ...prev, customFields: [...prev.customFields, field] }));
  };

  const updateCustomField = (id: string, field: keyof CustomField, value: string) => {
    setData(prev => ({ ...prev, customFields: prev.customFields.map(f => f.id === id ? { ...f, [field]: value } : f) }));
  };

  const removeCustomField = (id: string) => {
    setData(prev => ({ ...prev, customFields: prev.customFields.filter(f => f.id !== id) }));
  };

  const handleImageUpload = (field: 'profileImage' | 'companyLogo') => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = 'image/*';
    input.onchange = (e) => {
      const file = (e.target as HTMLInputElement).files?.[0];
      if (!file) return;
      const reader = new FileReader();
      reader.onload = (re) => {
        const result = re.target?.result as string;
        const img = new window.Image();
        img.onload = () => {
          const max = 200;
          let w = img.width, h = img.height;
          if (w > max || h > max) {
            const ratio = Math.min(max / w, max / h);
            w = Math.round(w * ratio);
            h = Math.round(h * ratio);
          }
          const canvas = document.createElement('canvas');
          canvas.width = w;
          canvas.height = h;
          const ctx = canvas.getContext('2d')!;
          ctx.drawImage(img, 0, 0, w, h);
          setData(prev => ({ ...prev, [field]: canvas.toDataURL('image/jpeg', 0.8) }));
        };
        img.src = result;
      };
      reader.readAsDataURL(file);
    };
    input.click();
  };

  const copyAsRichText = async () => {
    const el = document.getElementById('signature-preview');
    if (!el) return;
    try {
      const range = document.createRange();
      range.selectNodeContents(el);
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(range);
      document.execCommand('copy');
      sel?.removeAllRanges();
      setCopied('rich');
    } catch {
      await copyHtml();
      return;
    }
    setTimeout(() => setCopied(null), 2500);
  };

  const getSignatureHtml = useCallback(() => {
    const el = document.getElementById('signature-preview');
    if (!el) return '';
    return el.innerHTML;
  }, []);

  const copyHtml = async () => {
    const html = getSignatureHtml();
    try {
      await navigator.clipboard.writeText(html);
    } catch {
      const textarea = document.createElement('textarea');
      textarea.value = html;
      document.body.appendChild(textarea);
      textarea.select();
      document.execCommand('copy');
      document.body.removeChild(textarea);
    }
    setCopied('html');
    setTimeout(() => setCopied(null), 2500);
  };

  const downloadHtml = () => {
    const html = getSignatureHtml();
    const fullHtml = `<!DOCTYPE html>\n<html><head><meta charset="utf-8"><title>E-Mail-Signatur</title></head>\n<body style="margin:0;padding:20px;font-family:Arial,sans-serif;">\n${html}\n</body></html>`;
    const blob = new Blob([fullHtml], { type: 'text/html' });
    const link = document.createElement('a');
    link.download = `${data.fullName || 'signatur'}.html`;
    link.href = URL.createObjectURL(blob);
    link.click();
    URL.revokeObjectURL(link.href);
  };

  const downloadPng = async () => {
    const el = document.getElementById('signature-preview');
    if (!el) return;
    try {
      const dataUrl = await toPng(el, { pixelRatio: 2, backgroundColor: '#ffffff' });
      const link = document.createElement('a');
      link.download = `${data.fullName || 'signatur'}.png`;
      link.href = dataUrl;
      link.click();
      setCopied('png');
      setTimeout(() => setCopied(null), 2500);
    } catch (err) {
      console.error('PNG export failed:', err);
    }
  };

  const stepIndex = STEPS.indexOf(step);

  const inputClass = "w-full px-3 py-2 border border-accent-200 rounded-lg text-sm bg-white text-accent-900 placeholder:text-accent-400 focus:ring-0 focus:outline-none";
  const labelClass = "block text-xs font-medium text-accent-500 mb-1 uppercase tracking-wide";

  const renderPhoneHint = (field: 'phone' | 'mobile') => {
    const hint = phoneFormatHint(data[field]);
    if (!hint) return null;
    return <p className="text-xs text-accent-400 mt-1">Formatiert als: {hint}</p>;
  };

  const renderDetails = () => (
    <div className="space-y-5">
      <h3 className="text-xs font-semibold text-accent-500 uppercase tracking-wider">Pers&ouml;nliche Daten</h3>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div>
          <label className={labelClass}>Vollst&auml;ndiger Name *</label>
          <input type="text" value={data.fullName} onChange={e => updateData('fullName', e.target.value)}
            placeholder="Max Mustermann" className={inputClass} />
        </div>
        <div>
          <label className={labelClass}>Position</label>
          <input type="text" value={data.jobTitle} onChange={e => updateData('jobTitle', e.target.value)}
            placeholder="Gesch\u00e4ftsf\u00fchrer" className={inputClass} />
        </div>
        <div>
          <label className={labelClass}>Firma</label>
          <input type="text" value={data.company} onChange={e => updateData('company', e.target.value)}
            placeholder="Firma GmbH" className={inputClass} />
        </div>
        <div>
          <label className={labelClass}>Abteilung</label>
          <input type="text" value={data.department} onChange={e => updateData('department', e.target.value)}
            placeholder="Vertrieb" className={inputClass} />
        </div>
      </div>

      <h3 className="text-xs font-semibold text-accent-500 uppercase tracking-wider mt-6">Kontakt</h3>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div>
          <label className={labelClass}><Mail size={11} className="inline mr-1" />E-Mail</label>
          <input type="email" value={data.email} onChange={e => updateData('email', e.target.value)}
            placeholder="max@firma.de" className={inputClass} />
        </div>
        <div>
          <label className={labelClass}><Phone size={11} className="inline mr-1" />Telefon</label>
          <input type="tel" value={data.phone} onChange={e => updateData('phone', e.target.value)}
            placeholder="+49 221 123456" className={inputClass} />
          {renderPhoneHint('phone')}
        </div>
        <div>
          <label className={labelClass}><Smartphone size={11} className="inline mr-1" />Mobil</label>
          <input type="tel" value={data.mobile} onChange={e => updateData('mobile', e.target.value)}
            placeholder="+49 170 1234567" className={inputClass} />
          {renderPhoneHint('mobile')}
        </div>
        <div>
          <label className={labelClass}><Globe size={11} className="inline mr-1" />Website</label>
          <input type="url" value={data.website} onChange={e => updateData('website', e.target.value)}
            placeholder="www.firma.de" className={inputClass} />
        </div>
      </div>

      <h3 className="text-xs font-semibold text-accent-500 uppercase tracking-wider mt-6"><MapPin size={11} className="inline mr-1" />Adresse</h3>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div className="sm:col-span-2">
          <input type="text" value={data.street} onChange={e => updateData('street', e.target.value)}
            placeholder="Musterstraße 1" className={inputClass} />
        </div>
        <div>
          <input type="text" value={data.zip} onChange={e => updateData('zip', e.target.value)}
            placeholder="50679" className={inputClass} />
        </div>
        <div>
          <input type="text" value={data.city} onChange={e => updateData('city', e.target.value)}
            placeholder="Köln" className={inputClass} />
        </div>
        <div className="sm:col-span-2">
          <input type="text" value={data.country} onChange={e => updateData('country', e.target.value)}
            placeholder="Deutschland" className={inputClass} />
        </div>
      </div>

      <h3 className="text-xs font-semibold text-accent-500 uppercase tracking-wider mt-6">Eigene Felder</h3>
      {data.customFields.map((f) => (
        <div key={f.id} className="flex gap-2 items-start">
          <input type="text" value={f.label} onChange={e => updateCustomField(f.id, 'label', e.target.value)}
            placeholder="Bezeichnung" className={`flex-1 ${inputClass}`} />
          <input type="text" value={f.value} onChange={e => updateCustomField(f.id, 'value', e.target.value)}
            placeholder="Wert" className={`flex-1 ${inputClass}`} />
          <select value={f.type} onChange={e => updateCustomField(f.id, 'type', e.target.value)}
            className="px-2 py-2 border border-accent-200 rounded-lg text-sm bg-white">
            <option value="text">Text</option>
            <option value="link">Link</option>
          </select>
          <button onClick={() => removeCustomField(f.id)} className="p-2 text-accent-400 hover:text-red-500 hover:bg-red-50 rounded-lg transition-colors">
            <Trash2 size={16} />
          </button>
        </div>
      ))}
      <button onClick={addCustomField} className="flex items-center gap-1.5 text-sm text-accent-600 hover:text-accent-800 transition-colors">
        <Plus size={14} /> Feld hinzufügen
      </button>
    </div>
  );

  const renderImages = () => (
    <div className="space-y-6">
      <h3 className="text-xs font-semibold text-accent-500 uppercase tracking-wider">Profilfoto</h3>
      <div className="flex items-center gap-4">
        {data.profileImage ? (
          <div className="relative">
            <img src={data.profileImage} alt="Profil" className="w-16 h-16 rounded-full object-cover border border-accent-200" />
            <button onClick={() => updateData('profileImage', '')}
              className="absolute -top-1 -right-1 w-5 h-5 bg-accent-900 text-white rounded-full flex items-center justify-center text-xs hover:bg-red-600 transition-colors">&times;</button>
          </div>
        ) : (
          <div className="w-16 h-16 rounded-full bg-accent-100 border-2 border-dashed border-accent-300 flex items-center justify-center">
            <User size={24} className="text-accent-400" />
          </div>
        )}
        <button onClick={() => handleImageUpload('profileImage')}
          className="flex items-center gap-2 px-4 py-2 bg-accent-900 text-white rounded-lg hover:bg-accent-800 transition-colors text-sm font-medium">
          <Upload size={14} /> Hochladen
        </button>
      </div>
      <label className="flex items-center gap-2 text-sm text-accent-600 cursor-pointer">
        <input type="checkbox" checked={style.showProfileImage} onChange={e => updateStyle('showProfileImage', e.target.checked)} className="rounded border-accent-300 text-accent-900" />
        Profilfoto anzeigen
      </label>

      <h3 className="text-xs font-semibold text-accent-500 uppercase tracking-wider mt-6">Firmenlogo</h3>
      <div className="flex items-center gap-4">
        {data.companyLogo ? (
          <div className="relative">
            <img src={data.companyLogo} alt="Logo" className="h-10 object-contain rounded" />
            <button onClick={() => updateData('companyLogo', '')}
              className="absolute -top-1 -right-1 w-5 h-5 bg-accent-900 text-white rounded-full flex items-center justify-center text-xs hover:bg-red-600 transition-colors">&times;</button>
          </div>
        ) : (
          <div className="w-24 h-10 bg-accent-100 border-2 border-dashed border-accent-300 flex items-center justify-center rounded">
            <Building2 size={20} className="text-accent-400" />
          </div>
        )}
        <button onClick={() => handleImageUpload('companyLogo')}
          className="flex items-center gap-2 px-4 py-2 bg-accent-900 text-white rounded-lg hover:bg-accent-800 transition-colors text-sm font-medium">
          <Upload size={14} /> Hochladen
        </button>
      </div>
      <label className="flex items-center gap-2 text-sm text-accent-600 cursor-pointer">
        <input type="checkbox" checked={style.showLogo} onChange={e => updateStyle('showLogo', e.target.checked)} className="rounded border-accent-300 text-accent-900" />
        Firmenlogo anzeigen
      </label>
    </div>
  );

  const renderSocial = () => (
    <div className="space-y-4">
      <h3 className="text-xs font-semibold text-accent-500 uppercase tracking-wider">Social-Links</h3>
      <div className="space-y-3">
        {[
          { key: 'linkedin' as const, label: 'LinkedIn', placeholder: 'https://linkedin.com/in/profil' },
          { key: 'twitter' as const, label: 'X (Twitter)', placeholder: 'https://x.com/benutzername' },
          { key: 'instagram' as const, label: 'Instagram', placeholder: 'https://instagram.com/benutzername' },
          { key: 'facebook' as const, label: 'Facebook', placeholder: 'https://facebook.com/seite' },
        ].map(({ key, label, placeholder }) => (
          <div key={key}>
            <label className={labelClass}><Link size={11} className="inline mr-1" />{label}</label>
            <input type="url" value={data[key]} onChange={e => updateData(key, e.target.value)}
              placeholder={placeholder} className={inputClass} />
          </div>
        ))}
      </div>

      <h3 className="text-xs font-semibold text-accent-500 uppercase tracking-wider mt-6"><QrCode size={11} className="inline mr-1" />QR-Code</h3>
      <label className="flex items-center gap-2 text-sm text-accent-600 cursor-pointer">
        <input type="checkbox" checked={style.includeQR} onChange={e => updateStyle('includeQR', e.target.checked)} className="rounded border-accent-300 text-accent-900" />
        QR-Code in Signatur anzeigen
      </label>
      {style.includeQR && (
        <div className="mt-2">
          <label className={labelClass}>QR-Code URL</label>
          <input type="url" value={style.qrUrl} onChange={e => updateStyle('qrUrl', e.target.value)}
            placeholder="https://ihre-website.de oder vCard-Link" className={inputClass} />
          <p className="text-xs text-accent-400 mt-1">Link zu Website, Buchungskalender oder digitaler Visitenkarte</p>
        </div>
      )}
    </div>
  );

  const renderTemplate = () => (
    <div className="space-y-4">
      <h3 className="text-xs font-semibold text-accent-500 uppercase tracking-wider">Vorlage wählen</h3>
      <div className="grid grid-cols-2 gap-3">
        {TEMPLATES.map((t) => (
          <button
            key={t}
            onClick={() => updateStyle('template', t)}
            className={`p-3 rounded-lg border-2 text-left transition-all ${
              style.template === t ? 'border-accent-900 bg-accent-50' : 'border-accent-200 hover:border-accent-400 bg-white'
            }`}
          >
            <div className="font-semibold text-sm text-accent-900">{TEMPLATE_LABELS[t].name}</div>
            <div className="text-xs text-accent-500 mt-0.5">{TEMPLATE_LABELS[t].desc}</div>
          </button>
        ))}
      </div>
    </div>
  );

  const renderDesign = () => (
    <div className="space-y-6">
      <h3 className="text-xs font-semibold text-accent-500 uppercase tracking-wider">Akzentfarbe</h3>
      <div className="flex flex-wrap gap-2">
        {Object.entries(ACCENT_COLORS).map(([name, hex]) => (
          <button
            key={name}
            onClick={() => updateStyle('accentColor', name)}
            className={`w-9 h-9 rounded-lg border-2 transition-all ${
              style.accentColor === name ? 'border-accent-900 scale-110 shadow-sm' : 'border-accent-200 hover:border-accent-400'
            }`}
            style={{ backgroundColor: hex }}
            title={name}
          />
        ))}
      </div>

      <h3 className="text-xs font-semibold text-accent-500 uppercase tracking-wider">Schriftart</h3>
      <div className="grid grid-cols-2 gap-2">
        {EMAIL_FONTS.map((f) => (
          <button
            key={f}
            onClick={() => updateStyle('font', f)}
            className={`px-3 py-2 rounded-lg border text-sm text-left transition-all ${
              style.font === f ? 'border-accent-900 bg-accent-50 text-accent-900' : 'border-accent-200 hover:border-accent-400 text-accent-600 bg-white'
            }`}
            style={{ fontFamily: f }}
          >
            {f}
          </button>
        ))}
      </div>

      <h3 className="text-xs font-semibold text-accent-500 uppercase tracking-wider">Schriftgröße</h3>
      <div className="flex items-center gap-3">
        <input
          type="range"
          min={10}
          max={18}
          value={style.fontSize}
          onChange={e => updateStyle('fontSize', parseInt(e.target.value))}
          className="flex-1 accent-accent-900"
        />
        <span className="text-sm font-mono text-accent-500 w-10">{style.fontSize}px</span>
      </div>

      <h3 className="text-xs font-semibold text-accent-500 uppercase tracking-wider">Layout</h3>
      <div className="flex gap-2">
        {(['horizontal', 'vertical'] as const).map((l) => (
          <button
            key={l}
            onClick={() => updateStyle('layout', l)}
            className={`px-4 py-2 rounded-lg border text-sm capitalize transition-all ${
              style.layout === l ? 'border-accent-900 bg-accent-50 text-accent-900' : 'border-accent-200 hover:border-accent-400 text-accent-600 bg-white'
            }`}
          >
            {l === 'horizontal' ? 'Horizontal' : 'Vertikal'}
          </button>
        ))}
      </div>
    </div>
  );

  const STEP_RENDERERS: Record<Step, () => React.JSX.Element> = {
    details: renderDetails,
    images: renderImages,
    social: renderSocial,
    template: renderTemplate,
    design: renderDesign,
  };

  return (
    <div className="min-h-screen bg-accent-50 font-sans">
      {/* Header */}
      <header className="bg-white border-b border-accent-200 sticky top-0 z-50">
        <div className="max-w-7xl mx-auto px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-8 h-8 bg-accent-900 rounded-lg flex items-center justify-center">
              <Mail size={16} className="text-white" />
            </div>
            <div>
              <h1 className="text-base font-bold text-accent-900">Signature Creator</h1>
              <p className="text-xs text-accent-500 hidden sm:block">Einheitliche Signaturen für alle Geräte</p>
            </div>
          </div>
          {/* Desktop export buttons */}
          <div className="hidden md:flex items-center gap-2">
            <button onClick={copyAsRichText}
              className="flex items-center gap-2 px-4 py-2 bg-accent-900 text-white rounded-lg hover:bg-accent-800 transition-colors text-sm font-medium">
              {copied === 'rich' ? <><Check size={16} /> Kopiert!</> : <><Copy size={16} /> Kopieren</>}
            </button>
            <button onClick={downloadPng}
              className="flex items-center gap-2 px-3 py-2 border border-accent-200 rounded-lg hover:bg-accent-100 transition-colors text-sm text-accent-700">
              <Download size={16} /> PNG
            </button>
            <button onClick={downloadHtml}
              className="flex items-center gap-2 px-3 py-2 border border-accent-200 rounded-lg hover:bg-accent-100 transition-colors text-sm text-accent-700">
              <FileText size={16} /> HTML
            </button>
            <button onClick={copyHtml}
              className="flex items-center gap-2 px-3 py-2 border border-accent-200 rounded-lg hover:bg-accent-100 transition-colors text-sm text-accent-700">
              <Code size={16} /> {copied === 'html' ? 'Kopiert!' : 'HTML-Code'}
            </button>
          </div>
        </div>
      </header>

      <div className="max-w-7xl mx-auto px-4 py-6 sig-layout flex gap-6">
        {/* Sidebar */}
        <div className="sig-sidebar w-80 md:w-96 flex-shrink-0">
          <div className="bg-white rounded-xl border border-accent-200 overflow-hidden sticky top-20">
            {/* Step tabs */}
            <div className="flex border-b border-accent-100 overflow-x-auto">
              {STEPS.map((s, i) => (
                <button
                  key={s}
                  onClick={() => setStep(s)}
                  className={`flex-shrink-0 py-3 px-3 sm:px-4 text-xs font-medium transition-colors flex items-center gap-1.5 ${
                    step === s ? 'text-accent-900 bg-accent-50 border-b-2 border-accent-900' : 'text-accent-500 hover:text-accent-700 hover:bg-accent-50'
                  } ${i < stepIndex ? 'text-accent-400' : ''}`}
                >
                  {STEP_ICONS[s]}
                  <span className="hidden sm:inline">{STEP_LABELS[s]}</span>
                </button>
              ))}
            </div>
            {/* Step content */}
            <div className="p-4 max-h-[calc(100vh-260px)] overflow-y-auto">
              {STEP_RENDERERS[step]()}
            </div>
            {/* Navigation */}
            <div className="flex justify-between p-4 border-t border-accent-100">
              <button
                onClick={() => setStep(STEPS[Math.max(0, stepIndex - 1)])}
                disabled={stepIndex === 0}
                className="flex items-center gap-1 text-sm text-accent-500 hover:text-accent-700 disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
              >
                <ChevronLeft size={16} /> Zurück
              </button>
              <button
                onClick={() => setStep(STEPS[Math.min(STEPS.length - 1, stepIndex + 1)])}
                disabled={stepIndex === STEPS.length - 1}
                className="flex items-center gap-1 text-sm text-accent-900 hover:text-accent-700 disabled:opacity-30 disabled:cursor-not-allowed transition-colors font-medium"
              >
                Weiter <ChevronRight size={16} />
              </button>
            </div>
          </div>
        </div>

        {/* Preview */}
        <div className="flex-1 sig-preview-area min-w-0">
          <div className="bg-white rounded-xl border border-accent-200 p-6 sticky top-20">
            <div className="flex items-center justify-between mb-4">
              <h2 className="font-semibold text-accent-900 flex items-center gap-2 text-sm">
                <Eye size={16} /> Vorschau
              </h2>
              <div className="flex gap-1.5">
                <button
                  onClick={() => setExportMode('visual')}
                  className={"px-3 py-1.5 rounded-lg text-xs font-medium transition-colors " + (
                    exportMode === 'visual' ? 'bg-accent-900 text-white' : 'text-accent-500 hover:bg-accent-100'
                  )}
                >
                  Visuell
                </button>
                <button
                  onClick={() => setExportMode('html')}
                  className={"px-3 py-1.5 rounded-lg text-xs font-medium transition-colors " + (
                    exportMode === 'html' ? 'bg-accent-900 text-white' : 'text-accent-500 hover:bg-accent-100'
                  )}
                >
                  HTML-Code
                </button>
              </div>
            </div>

            {exportMode === 'visual' ? (
              <div className="border border-accent-100 rounded-lg p-6 bg-white min-h-[200px] overflow-x-auto">
                {data.fullName ? (
                  <div id="signature-preview" ref={previewRef}>
                    <SignaturePreview data={data} style={style} />
                  </div>
                ) : (
                  <div className="flex items-center justify-center h-40 text-accent-400 text-sm">
                    Namen eingeben für Vorschau &rarr;
                  </div>
                )}
              </div>
            ) : (
              <div className="border border-accent-100 rounded-lg p-4 bg-accent-950 overflow-x-auto max-h-[500px] overflow-y-auto">
                <pre className="text-xs text-green-400 whitespace-pre-wrap font-mono">
                  {data.fullName ? getSignatureHtml() : '<!-- Namen eingeben um HTML zu generieren -->'}
                </pre>
              </div>
            )}

            {/* How-to section */}
            <div className="mt-4 p-4 bg-accent-50 rounded-lg border border-accent-200">
              <button
                onClick={() => setShowHowTo(!showHowTo)}
                className="w-full flex items-center justify-between text-sm font-medium text-accent-700"
              >
                <span className="flex items-center gap-2"><MessageCircle size={14} /> So fügen Sie die Signatur ein</span>
                <ChevronRight size={14} className={"transition-transform " + (showHowTo ? 'rotate-90' : '')} />
              </button>
              {showHowTo && (
                <div className="mt-3 space-y-3 text-xs text-accent-700">
                  <div>
                    <p className="font-semibold text-accent-900">Gmail</p>
                    <ol className="list-decimal list-inside space-y-0.5 text-accent-600">
                      <li>Einstellungen &rarr; Alle Einstellungen anzeigen &rarr; Signatur</li>
                      <li>&quot;Neue erstellen&quot; klicken</li>
                      <li>Kopieren-Schaltfläche oben verwenden</li>
                      <li>In Gmail einfügen (Strg+V / Cmd+V)</li>
                    </ol>
                  </div>
                  <div>
                    <p className="font-semibold text-accent-900">Outlook</p>
                    <ol className="list-decimal list-inside space-y-0.5 text-accent-600">
                      <li>Einstellungen &rarr; E-Mail &rarr; Verfassen und antworten</li>
                      <li>Signatur bearbeiten</li>
                      <li>Kopierten Text einfügen (Strg+V)</li>
                    </ol>
                  </div>
                  <div>
                    <p className="font-semibold text-accent-900">Apple Mail (Mac)</p>
                    <ol className="list-decimal list-inside space-y-0.5 text-accent-600">
                      <li>Mail &rarr; Einstellungen &rarr; Signaturen</li>
                      <li>Neue Signatur erstellen</li>
                      <li>Kopierten Text einfügen (Cmd+V)</li>
                    </ol>
                  </div>
                  <div>
                    <p className="font-semibold text-accent-900">Apple Mail (iPhone)</p>
                    <ol className="list-decimal list-inside space-y-0.5 text-accent-600">
                      <li>Einstellungen &rarr; Mail &rarr; Signatur</li>
                      <li>Signatur auswählen und gesamten Text ersetzen</li>
                      <li>Einfügen des kopierten Textes</li>
                    </ol>
                  </div>
                  <div>
                    <p className="font-semibold text-accent-900">Thunderbird</p>
                    <ol className="list-decimal list-inside space-y-0.5 text-accent-600">
                      <li>Konteneinstellungen &rarr; Signatur-Text</li>
                      <li>HTML-Code einfügen oder Datei anhängen</li>
                    </ol>
                  </div>
                  <div className="mt-3 p-3 bg-white rounded-lg border border-accent-200">
                    <p className="text-accent-900 font-semibold">Tipp für einheitliche Darstellung:</p>
                    <p className="text-accent-600 mt-1">Verwenden Sie die &quot;Kopieren&quot;-Schaltfläche oben, um die Signatur als formatierten Text zu kopieren. Fügen Sie sie auf MacBook und iPhone ein, um konsistente Ergebnisse zu erzielen.</p>
                  </div>
                </div>
              )}
            </div>
          </div>
        </div>
      </div>

      {/* Mobile sticky bottom bar */}
      <div className="sig-bottom-bar md:hidden">
        <div className="flex gap-2">
          <button onClick={copyAsRichText}
            className="flex-1 flex items-center justify-center gap-2 px-4 py-3 bg-accent-900 text-white rounded-lg text-sm font-medium">
            {copied === 'rich' ? <><Check size={16} /> Kopiert!</> : <><Copy size={16} /> Kopieren</>}
          </button>
          <button onClick={downloadPng}
            className="flex items-center justify-center px-3 py-3 border border-accent-200 rounded-lg text-sm text-accent-700">
            <Download size={16} />
          </button>
          <button onClick={downloadHtml}
            className="flex items-center justify-center px-3 py-3 border border-accent-200 rounded-lg text-sm text-accent-700">
            <FileText size={16} />
          </button>
          <button onClick={copyHtml}
            className="flex items-center justify-center px-3 py-3 border border-accent-200 rounded-lg text-sm text-accent-700">
            <Code size={16} />
          </button>
        </div>
      </div>
    </div>
  );
}
