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

export interface SignatureStyle {
  template: TemplateName;
  accentColor: AccentColor;
  font: FontName;
  fontSize: number;
  includeQR: boolean;
  qrUrl: string;
  showProfileImage: boolean;
  showLogo: boolean;
  layout: 'horizontal' | 'vertical';
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
  customFields: [],
  profileImage: null,
  companyLogo: null,
};

export const DEFAULT_STYLE: SignatureStyle = {
  template: 'modern',
  accentColor: 'slate',
  font: 'Arial',
  fontSize: 14,
  includeQR: false,
  qrUrl: '',
  showProfileImage: true,
  showLogo: true,
  layout: 'horizontal',
};