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

export type TemplateName = 'modern' | 'classic' | 'minimal' | 'professional' | 'creative' | 'compact';
export type AccentColor = 'blue' | 'green' | 'orange' | 'red' | 'purple' | 'cyan' | 'lime' | 'amber';
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
};

export const EMAIL_FONTS: FontName[] = [
  'Arial', 'Helvetica', 'Georgia', 'Times New Roman',
  'Verdana', 'Tahoma', 'Trebuchet MS', 'Courier New'
];

export const TEMPLATES: TemplateName[] = [
  'modern', 'classic', 'minimal', 'professional', 'creative', 'compact'
];

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
  accentColor: 'blue',
  font: 'Arial',
  fontSize: 14,
  includeQR: false,
  qrUrl: '',
  showProfileImage: true,
  showLogo: true,
  layout: 'horizontal',
};