export interface SignatureData {
  // Personal
  fullName: string;
  jobTitle: string;
  company: string;
  department: string;
  
  // Contact
  email: string;
  phone: string;
  mobile: string;
  website: string;
  
  // Address
  street: string;
  city: string;
  zip: string;
  country: string;
  
  // Social
  linkedin: string;
  twitter: string;
  instagram: string;
  facebook: string;
  
  // CTA
  ctaLabel: string;
  ctaUrl: string;
  
  // Banner
  bannerImage: string | null;
  bannerUrl: string;
  bannerAlt: string;
  
  // Custom fields
  customFields: CustomField[];
  
  // Images
  profileImage: string | null;
  companyLogo: string | null;
}

export interface CustomField {
  id: string;
  label: string;
  value: string;
  type: 'text' | 'link';
}

export type TemplateName = 'modern' | 'classic' | 'minimal' | 'professional' | 'creative' | 'compact' | 'bold' | 'elegant' | 'corporate' | 'divider' | 'stacked' | 'boxed';
export type AccentColor = 'blue' | 'green' | 'orange' | 'red' | 'purple' | 'cyan' | 'lime' | 'amber' | 'pink' | 'indigo' | 'teal' | 'rose' | 'slate' | 'emerald' | 'violet' | 'fuchsia';
export type FontName = 'Arial' | 'Helvetica' | 'Georgia' | 'Times New Roman' | 'Verdana' | 'Tahoma' | 'Trebuchet MS' | 'Courier New';
export type SocialIconStyle = 'outline' | 'filled' | 'rounded' | 'monochrome' | 'brand';
export type SeparatorStyle = 'line' | 'dashed' | 'pipe' | 'accent' | 'gradient' | 'none';
export type CtaStyle = 'rounded' | 'pill' | 'minimal';
export type DevicePreview = 'desktop' | 'tablet' | 'phone';
export type PreviewMode = 'light' | 'dark';

export interface SignatureStyle {
  template: TemplateName;
  accentColor: AccentColor;
  customAccentHex: string | null;
  font: FontName;
  fontSize: number;
  includeQR: boolean;
  qrUrl: string;
  showProfileImage: boolean;
  showLogo: boolean;
  layout: 'horizontal' | 'vertical';
  socialIconStyle: SocialIconStyle;
  separatorStyle: SeparatorStyle;
  ctaStyle: CtaStyle;
  showCta: boolean;
  showBanner: boolean;
  optimizeDarkMode: boolean;
}

export const ACCENT_COLORS: Record<AccentColor, string> = {
  blue: '#2563eb',
  green: '#16a34a',
  orange: '#ea580c',
  red: '#dc2626',
  purple: '#9333ea',
  cyan: '#06b6d4',
  lime: '#84cc16',
  amber: '#f59e0b',
  pink: '#ec4899',
  indigo: '#6366f1',
  teal: '#14b8a6',
  rose: '#f43f5e',
  slate: '#475569',
  emerald: '#10b981',
  violet: '#8b5cf6',
  fuchsia: '#d946ef',
};

export const SOCIAL_ICON_STYLES: { key: SocialIconStyle; label: string; desc: string }[] = [
  { key: 'outline', label: 'Outline', desc: 'Linien' },
  { key: 'filled', label: 'Filled', desc: 'Gefüllt' },
  { key: 'rounded', label: 'Rounded', desc: 'Abgerundet' },
  { key: 'monochrome', label: 'Mono', desc: 'Schwarz' },
  { key: 'brand', label: 'Brand', desc: 'Farbig' },
];

export const SEPARATOR_STYLES: { key: SeparatorStyle; label: string }[] = [
  { key: 'line', label: 'Linie' },
  { key: 'dashed', label: 'Gestrichelt' },
  { key: 'pipe', label: 'Pipe |' },
  { key: 'accent', label: 'Akzent' },
  { key: 'gradient', label: 'Verlauf' },
  { key: 'none', label: 'Ohne' },
];

export const CTA_STYLES: { key: CtaStyle; label: string }[] = [
  { key: 'rounded', label: 'Abgerundet' },
  { key: 'pill', label: 'Pille' },
  { key: 'minimal', label: 'Minimal' },
];

export const EMAIL_FONTS: FontName[] = [
  'Arial', 'Helvetica', 'Georgia', 'Times New Roman',
  'Verdana', 'Tahoma', 'Trebuchet MS', 'Courier New'
];

export const TEMPLATES: TemplateName[] = [
  'modern', 'classic', 'minimal', 'professional', 'creative', 'compact',
  'bold', 'elegant', 'corporate', 'divider', 'stacked', 'boxed'
];

export const TEMPLATE_LABELS: Record<TemplateName, { name: string; desc: string }> = {
  modern: { name: 'Modern', desc: 'Clean with accent divider' },
  classic: { name: 'Classic', desc: 'Left border accent bar' },
  minimal: { name: 'Minimal', desc: 'Just the essentials' },
  professional: { name: 'Professional', desc: 'Bold name, accent line' },
  creative: { name: 'Creative', desc: 'Color accent sidebar' },
  compact: { name: 'Compact', desc: 'One-liner style' },
  bold: { name: 'Bold', desc: 'Strong header bar' },
  elegant: { name: 'Elegant', desc: 'Refined thin rules' },
  corporate: { name: 'Corporate', desc: 'Structured 2-column' },
  divider: { name: 'Divider', desc: 'Rule separators' },
  stacked: { name: 'Stacked', desc: 'Centered vertical' },
  boxed: { name: 'Boxed', desc: 'Card with accent top' },
};

export const BRAND_COLORS: Record<string, string> = {
  linkedin: '#0a66c2',
  twitter: '#000000',
  instagram: '#e4405f',
  facebook: '#1877f2',
};

export const DEFAULT_SIGNATURE: SignatureData = {
  fullName: '',
  jobTitle: '',
  company: '',
  department: '',
  email: '',
  phone: '',
  mobile: '',
  website: '',
  street: '',
  city: '',
  zip: '',
  country: '',
  linkedin: '',
  twitter: '',
  instagram: '',
  facebook: '',
  ctaLabel: 'Termin buchen',
  ctaUrl: '',
  bannerImage: null,
  bannerUrl: '',
  bannerAlt: '',
  customFields: [],
  profileImage: null,
  companyLogo: null,
};

export const DEFAULT_STYLE: SignatureStyle = {
  template: 'modern',
  accentColor: 'slate',
  customAccentHex: null,
  font: 'Arial',
  fontSize: 14,
  includeQR: false,
  qrUrl: '',
  showProfileImage: true,
  showLogo: true,
  layout: 'horizontal',
  socialIconStyle: 'outline',
  separatorStyle: 'line',
  ctaStyle: 'rounded',
  showCta: false,
  showBanner: false,
  optimizeDarkMode: false,
};