import { useState, useCallback } from 'react';
import type { SignatureData, SignatureStyle, CustomField } from '../types';
import { DEFAULT_SIGNATURE, DEFAULT_STYLE, ACCENT_COLORS, EMAIL_FONTS, TEMPLATES } from '../types';
import { SignaturePreview } from './SignaturePreview';
import { toPng } from 'html-to-image';
import { Mail, Phone, Smartphone, Globe, MapPin, Link, Plus, Trash2, Upload, Download, Image, QrCode, ChevronRight, ChevronLeft, Eye, Code, User, Building2, Palette } from 'lucide-react';

type Step = 'details' | 'images' | 'social' | 'template' | 'design';
const STEPS: Step[] = ['details', 'images', 'social', 'template', 'design'];
const STEP_LABELS: Record<Step, string> = {
  details: 'Details',
  images: 'Images',
  social: 'Social',
  template: 'Template',
  design: 'Design',
};
const STEP_ICONS: Record<Step, React.ReactNode> = {
  details: <User size={16} />,
  images: <Image size={16} />,
  social: <Globe size={16} />,
  template: <Mail size={16} />,
  design: <Palette size={16} />,
};

export function SignatureEditor() {
  const [data, setData] = useState<SignatureData>(DEFAULT_SIGNATURE);
  const [style, setStyle] = useState<SignatureStyle>(DEFAULT_STYLE);
  const [step, setStep] = useState<Step>('details');
  const [copied, setCopied] = useState<string | null>(null);
  const [exportMode, setExportMode] = useState<'visual' | 'html'>('visual');

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
    setTimeout(() => setCopied(null), 2000);
  };

  const downloadPng = async () => {
    const el = document.getElementById('signature-preview');
    if (!el) return;
    try {
      const dataUrl = await toPng(el, { pixelRatio: 2, backgroundColor: '#ffffff' });
      const link = document.createElement('a');
      link.download = `${data.fullName || 'signature'}.png`;
      link.href = dataUrl;
      link.click();
      setCopied('png');
      setTimeout(() => setCopied(null), 2000);
    } catch (err) {
      console.error('PNG export failed:', err);
    }
  };

  const stepIndex = STEPS.indexOf(step);

  const inputClass = "w-full px-3 py-2 border border-gray-200 rounded-lg text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent outline-none";

  const renderDetails = () => (
    <div className="space-y-4">
      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider">Personal Information</h3>
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="block text-xs text-gray-500 mb-1">Full Name *</label>
          <input type="text" value={data.fullName} onChange={e => updateData('fullName', e.target.value)}
            placeholder="Max Mustermann" className={inputClass} />
        </div>
        <div>
          <label className="block text-xs text-gray-500 mb-1">Job Title</label>
          <input type="text" value={data.jobTitle} onChange={e => updateData('jobTitle', e.target.value)}
            placeholder="Geschäftsführer" className={inputClass} />
        </div>
        <div>
          <label className="block text-xs text-gray-500 mb-1">Company</label>
          <input type="text" value={data.company} onChange={e => updateData('company', e.target.value)}
            placeholder="Firma GmbH" className={inputClass} />
        </div>
        <div>
          <label className="block text-xs text-gray-500 mb-1">Department</label>
          <input type="text" value={data.department} onChange={e => updateData('department', e.target.value)}
            placeholder="Vertrieb" className={inputClass} />
        </div>
      </div>

      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider mt-6">Contact</h3>
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="block text-xs text-gray-500 mb-1"><Mail size={12} className="inline mr-1" />Email</label>
          <input type="email" value={data.email} onChange={e => updateData('email', e.target.value)}
            placeholder="max@firma.de" className={inputClass} />
        </div>
        <div>
          <label className="block text-xs text-gray-500 mb-1"><Phone size={12} className="inline mr-1" />Phone</label>
          <input type="tel" value={data.phone} onChange={e => updateData('phone', e.target.value)}
            placeholder="+49 221 123456" className={inputClass} />
        </div>
        <div>
          <label className="block text-xs text-gray-500 mb-1"><Smartphone size={12} className="inline mr-1" />Mobile</label>
          <input type="tel" value={data.mobile} onChange={e => updateData('mobile', e.target.value)}
            placeholder="+49 170 1234567" className={inputClass} />
        </div>
        <div>
          <label className="block text-xs text-gray-500 mb-1"><Globe size={12} className="inline mr-1" />Website</label>
          <input type="url" value={data.website} onChange={e => updateData('website', e.target.value)}
            placeholder="www.firma.de" className={inputClass} />
        </div>
      </div>

      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider mt-6"><MapPin size={12} className="inline mr-1" />Address</h3>
      <div className="grid grid-cols-2 gap-3">
        <div className="col-span-2">
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
        <div className="col-span-2">
          <input type="text" value={data.country} onChange={e => updateData('country', e.target.value)}
            placeholder="Deutschland" className={inputClass} />
        </div>
      </div>

      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider mt-6">Custom Fields</h3>
      {data.customFields.map((f) => (
        <div key={f.id} className="flex gap-2 items-start">
          <input type="text" value={f.label} onChange={e => updateCustomField(f.id, 'label', e.target.value)}
            placeholder="Label" className={`flex-1 ${inputClass}`} />
          <input type="text" value={f.value} onChange={e => updateCustomField(f.id, 'value', e.target.value)}
            placeholder="Value" className={`flex-1 ${inputClass}`} />
          <select value={f.type} onChange={e => updateCustomField(f.id, 'type', e.target.value)}
            className="px-2 py-2 border border-gray-200 rounded-lg text-sm">
            <option value="text">Text</option>
            <option value="link">Link</option>
          </select>
          <button onClick={() => removeCustomField(f.id)} className="p-2 text-red-400 hover:text-red-600 hover:bg-red-50 rounded-lg">
            <Trash2 size={16} />
          </button>
        </div>
      ))}
      <button onClick={addCustomField} className="flex items-center gap-1 text-sm text-blue-600 hover:text-blue-800">
        <Plus size={14} /> Add Custom Field
      </button>
    </div>
  );

  const renderImages = () => (
    <div className="space-y-6">
      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider">Profile Photo</h3>
      <div className="flex items-center gap-4">
        {data.profileImage ? (
          <div className="relative">
            <img src={data.profileImage} alt="Profile" className="w-20 h-20 rounded-full object-cover border-2 border-gray-200" />
            <button onClick={() => updateData('profileImage', '')}
              className="absolute -top-2 -right-2 w-6 h-6 bg-red-500 text-white rounded-full flex items-center justify-center text-xs hover:bg-red-600">×</button>
          </div>
        ) : (
          <div className="w-20 h-20 rounded-full bg-gray-100 border-2 border-dashed border-gray-300 flex items-center justify-center">
            <User size={32} className="text-gray-400" />
          </div>
        )}
        <button onClick={() => handleImageUpload('profileImage')}
          className="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors text-sm">
          <Upload size={16} /> Upload Photo
        </button>
      </div>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" checked={style.showProfileImage} onChange={e => updateStyle('showProfileImage', e.target.checked)} className="rounded border-gray-300" />
        Show profile photo in signature
      </label>

      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider mt-6">Company Logo</h3>
      <div className="flex items-center gap-4">
        {data.companyLogo ? (
          <div className="relative">
            <img src={data.companyLogo} alt="Logo" className="h-12 object-contain" />
            <button onClick={() => updateData('companyLogo', '')}
              className="absolute -top-2 -right-2 w-6 h-6 bg-red-500 text-white rounded-full flex items-center justify-center text-xs hover:bg-red-600">×</button>
          </div>
        ) : (
          <div className="w-24 h-12 bg-gray-100 border-2 border-dashed border-gray-300 flex items-center justify-center">
            <Building2 size={24} className="text-gray-400" />
          </div>
        )}
        <button onClick={() => handleImageUpload('companyLogo')}
          className="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors text-sm">
          <Upload size={16} /> Upload Logo
        </button>
      </div>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" checked={style.showLogo} onChange={e => updateStyle('showLogo', e.target.checked)} className="rounded border-gray-300" />
        Show company logo in signature
      </label>
    </div>
  );

  const renderSocial = () => (
    <div className="space-y-4">
      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider">Social Links</h3>
      <div className="space-y-3">
        <div>
          <label className="block text-xs text-gray-500 mb-1"><Link size={12} className="inline mr-1" />LinkedIn</label>
          <input type="url" value={data.linkedin} onChange={e => updateData('linkedin', e.target.value)}
            placeholder="https://linkedin.com/in/profile" className={inputClass} />
        </div>
        <div>
          <label className="block text-xs text-gray-500 mb-1"><Link size={12} className="inline mr-1" />X (Twitter)</label>
          <input type="url" value={data.twitter} onChange={e => updateData('twitter', e.target.value)}
            placeholder="https://x.com/username" className={inputClass} />
        </div>
        <div>
          <label className="block text-xs text-gray-500 mb-1"><Link size={12} className="inline mr-1" />Instagram</label>
          <input type="url" value={data.instagram} onChange={e => updateData('instagram', e.target.value)}
            placeholder="https://instagram.com/username" className={inputClass} />
        </div>
        <div>
          <label className="block text-xs text-gray-500 mb-1"><Link size={12} className="inline mr-1" />Facebook</label>
          <input type="url" value={data.facebook} onChange={e => updateData('facebook', e.target.value)}
            placeholder="https://facebook.com/page" className={inputClass} />
        </div>
      </div>

      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider mt-6"><QrCode size={12} className="inline mr-1" />QR Code</h3>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" checked={style.includeQR} onChange={e => updateStyle('includeQR', e.target.checked)} className="rounded border-gray-300" />
        Include QR code in signature
      </label>
      {style.includeQR && (
        <div className="mt-2">
          <label className="block text-xs text-gray-500 mb-1">QR Code URL</label>
          <input type="url" value={style.qrUrl} onChange={e => updateStyle('qrUrl', e.target.value)}
            placeholder="https://your-website.com or vcard link" className={inputClass} />
          <p className="text-xs text-gray-400 mt-1">Link to website, booking calendar, or digital business card</p>
        </div>
      )}
    </div>
  );

  const TEMPLATE_THUMBNAILS: Record<string, { name: string; desc: string }> = {
    modern: { name: 'Modern', desc: 'Clean with accent divider' },
    classic: { name: 'Classic', desc: 'Left border accent bar' },
    minimal: { name: 'Minimal', desc: 'Just the essentials' },
    professional: { name: 'Professional', desc: 'Bold name, accent line' },
    creative: { name: 'Creative', desc: 'Color accent sidebar' },
    compact: { name: 'Compact', desc: 'One-liner style' },
  };

  const renderTemplate = () => (
    <div className="space-y-4">
      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider">Choose Template</h3>
      <div className="grid grid-cols-2 gap-3">
        {TEMPLATES.map((t) => (
          <button
            key={t}
            onClick={() => updateStyle('template', t)}
            className={`p-4 rounded-lg border-2 text-left transition-all ${
              style.template === t ? 'border-blue-500 bg-blue-50' : 'border-gray-200 hover:border-gray-300'
            }`}
          >
            <div className="font-semibold text-sm">{TEMPLATE_THUMBNAILS[t].name}</div>
            <div className="text-xs text-gray-500 mt-1">{TEMPLATE_THUMBNAILS[t].desc}</div>
          </button>
        ))}
      </div>
    </div>
  );

  const renderDesign = () => (
    <div className="space-y-6">
      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider">Accent Color</h3>
      <div className="flex flex-wrap gap-2">
        {Object.entries(ACCENT_COLORS).map(([name, hex]) => (
          <button
            key={name}
            onClick={() => updateStyle('accentColor', name)}
            className={`w-10 h-10 rounded-lg border-2 transition-all ${
              style.accentColor === name ? 'border-gray-800 scale-110' : 'border-gray-200 hover:border-gray-400'
            }`}
            style={{ backgroundColor: hex }}
            title={name}
          />
        ))}
      </div>

      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider">Font</h3>
      <div className="grid grid-cols-2 gap-2">
        {EMAIL_FONTS.map((f) => (
          <button
            key={f}
            onClick={() => updateStyle('font', f)}
            className={`px-3 py-2 rounded-lg border text-sm text-left transition-all ${
              style.font === f ? 'border-blue-500 bg-blue-50' : 'border-gray-200 hover:border-gray-300'
            }`}
            style={{ fontFamily: f }}
          >
            {f}
          </button>
        ))}
      </div>

      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider">Font Size</h3>
      <div className="flex items-center gap-3">
        <input
          type="range"
          min={10}
          max={18}
          value={style.fontSize}
          onChange={e => updateStyle('fontSize', parseInt(e.target.value))}
          className="flex-1"
        />
        <span className="text-sm font-mono w-8">{style.fontSize}px</span>
      </div>

      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider">Layout</h3>
      <div className="flex gap-2">
        {(['horizontal', 'vertical'] as const).map((l) => (
          <button
            key={l}
            onClick={() => updateStyle('layout', l)}
            className={`px-4 py-2 rounded-lg border text-sm capitalize transition-all ${
              style.layout === l ? 'border-blue-500 bg-blue-50' : 'border-gray-200 hover:border-gray-300'
            }`}
          >
            {l}
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
    <div className="min-h-screen bg-gray-50">
      {/* Header */}
      <header className="bg-white border-b border-gray-200 sticky top-0 z-50">
        <div className="max-w-7xl mx-auto px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-8 h-8 bg-blue-600 rounded-lg flex items-center justify-center">
              <Mail size={16} className="text-white" />
            </div>
            <h1 className="text-lg font-bold text-gray-900">Signature Creator</h1>
          </div>
          <div className="flex items-center gap-2">
            <button onClick={copyHtml}
              className="flex items-center gap-2 px-4 py-2 bg-white border border-gray-200 rounded-lg hover:bg-gray-50 transition-colors text-sm font-medium">
              <Code size={16} />
              {copied === 'html' ? '✓ Copied!' : 'Copy HTML'}
            </button>
            <button onClick={downloadPng}
              className="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors text-sm font-medium">
              <Download size={16} />
              {copied === 'png' ? '✓ Downloaded!' : 'Download PNG'}
            </button>
          </div>
        </div>
      </header>

      <div className="max-w-7xl mx-auto px-4 py-6">
        <div className="flex gap-6">
          {/* Sidebar */}
          <div className="w-80 flex-shrink-0">
            <div className="bg-white rounded-xl border border-gray-200 overflow-hidden sticky top-20">
              {/* Step tabs */}
              <div className="flex border-b border-gray-100">
                {STEPS.map((s, i) => (
                  <button
                    key={s}
                    onClick={() => setStep(s)}
                    className={`flex-1 py-3 px-2 text-xs font-medium transition-colors flex flex-col items-center gap-1 ${
                      step === s ? 'text-blue-600 bg-blue-50' : 'text-gray-500 hover:text-gray-700 hover:bg-gray-50'
                    } ${i < stepIndex ? 'text-green-600' : ''}`}
                  >
                    {STEP_ICONS[s]}
                    {STEP_LABELS[s]}
                  </button>
                ))}
              </div>
              {/* Step content */}
              <div className="p-4 max-h-[calc(100vh-200px)] overflow-y-auto">
                {STEP_RENDERERS[step]()}
              </div>
              {/* Navigation */}
              <div className="flex justify-between p-4 border-t border-gray-100">
                <button
                  onClick={() => setStep(STEPS[Math.max(0, stepIndex - 1)])}
                  disabled={stepIndex === 0}
                  className="flex items-center gap-1 text-sm text-gray-500 hover:text-gray-700 disabled:opacity-30 disabled:cursor-not-allowed"
                >
                  <ChevronLeft size={16} /> Back
                </button>
                <button
                  onClick={() => setStep(STEPS[Math.min(STEPS.length - 1, stepIndex + 1)])}
                  disabled={stepIndex === STEPS.length - 1}
                  className="flex items-center gap-1 text-sm text-blue-600 hover:text-blue-800 disabled:opacity-30 disabled:cursor-not-allowed"
                >
                  Next <ChevronRight size={16} />
                </button>
              </div>
            </div>
          </div>

          {/* Preview */}
          <div className="flex-1">
            <div className="bg-white rounded-xl border border-gray-200 p-6 sticky top-20">
              <div className="flex items-center justify-between mb-4">
                <h2 className="font-semibold text-gray-900 flex items-center gap-2">
                  <Eye size={18} /> Live Preview
                </h2>
                <div className="flex gap-2">
                  <button
                    onClick={() => setExportMode('visual')}
                    className={`px-3 py-1.5 rounded-lg text-xs font-medium transition-colors ${
                      exportMode === 'visual' ? 'bg-blue-100 text-blue-700' : 'text-gray-500 hover:bg-gray-100'
                    }`}
                  >
                    Visual
                  </button>
                  <button
                    onClick={() => setExportMode('html')}
                    className={`px-3 py-1.5 rounded-lg text-xs font-medium transition-colors ${
                      exportMode === 'html' ? 'bg-blue-100 text-blue-700' : 'text-gray-500 hover:bg-gray-100'
                    }`}
                  >
                    HTML Code
                  </button>
                </div>
              </div>

              {exportMode === 'visual' ? (
                <div className="border border-gray-100 rounded-lg p-6 bg-white min-h-[200px]">
                  {data.fullName ? (
                    <div id="signature-preview">
                      <SignaturePreview data={data} style={style} />
                    </div>
                  ) : (
                    <div className="flex items-center justify-center h-40 text-gray-400 text-sm">
                      Enter your name to see a live preview →
                    </div>
                  )}
                </div>
              ) : (
                <div className="border border-gray-100 rounded-lg p-4 bg-gray-900 overflow-x-auto max-h-[500px] overflow-y-auto">
                  <pre className="text-xs text-green-400 whitespace-pre-wrap font-mono">
                    {data.fullName ? getSignatureHtml() : '<!-- Enter your name to generate HTML -->'}
                  </pre>
                </div>
              )}

              <div className="mt-4 p-3 bg-blue-50 rounded-lg">
                <p className="text-xs text-blue-700">
                  <strong>Tip:</strong> For consistent signatures across MacBook and iPhone, copy the HTML code and paste it into your email client's signature settings on each device.
                </p>
              </div>

              <details className="mt-3">
                <summary className="text-xs text-gray-500 cursor-pointer hover:text-gray-700">
                  📧 How to add signature in Gmail, Outlook, Apple Mail
                </summary>
                <div className="mt-2 text-xs text-gray-600 space-y-2">
                  <p><strong>Gmail:</strong> Settings → See all settings → Signature → Paste HTML (use "Create new" → Ctrl+Shift+V)</p>
                  <p><strong>Outlook:</strong> Settings → View all Outlook settings → Mail → Compose and reply → Signature → Paste HTML</p>
                  <p><strong>Apple Mail (Mac):</strong> Mail → Preferences → Signatures → Create new → Paste (use Edit → Paste and Match Style)</p>
                  <p><strong>Apple Mail (iPhone):</strong> Settings → Mail → Signature → Paste the text, then select all and apply formatting</p>
                  <p><strong>Thunderbird:</strong> Account Settings → Signature text → Paste HTML</p>
                </div>
              </details>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}