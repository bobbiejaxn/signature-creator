import React from 'react';
import type { SignatureData, SignatureStyle } from '../types';
import { ACCENT_COLORS } from '../types';
import { QRCodeSVG } from 'qrcode.react';

interface Props {
  data: SignatureData;
  style: SignatureStyle;
}

export function SignaturePreview({ data, style }: Props) {
  const accent = ACCENT_COLORS[style.accentColor];
  const font = style.font;
  const size = style.fontSize;
  const sm = size - 2;
  const lg = size + 4;
  const addressLine = [data.street, data.zip, data.city, data.country].filter(Boolean).join(', ');

  const socials = [
    data.linkedin ? { label: 'LinkedIn', href: data.linkedin } : null,
    data.twitter ? { label: 'X', href: data.twitter } : null,
    data.instagram ? { label: 'Instagram', href: data.instagram } : null,
    data.facebook ? { label: 'Facebook', href: data.facebook } : null,
  ].filter(Boolean) as { label: string; href: string }[];

  const renderSocialLinks = (sep: string = ' · ') => (
    <>
      {socials.map((s, i) => (
        <span key={s.label}>
          {i > 0 && <span style={{ color: '#ccc' }}>{sep}</span>}
          <a href={s.href} style={{ color: accent, textDecoration: 'none' }}>{s.label}</a>
        </span>
      ))}
    </>
  );

  const renderContactLines = (showIcons: boolean = true) => (
    <>
      {(data.phone || data.mobile) && (
        <tr>
          <td style={{ color: '#444', fontSize: `${sm}px` }}>
            {data.phone && (showIcons ? '☎ ' : '')}{data.phone}
            {data.phone && data.mobile ? '  |  ' : ''}
            {data.mobile && (showIcons ? '📱 ' : '')}{data.mobile}
          </td>
        </tr>
      )}
      {data.email && (
        <tr>
          <td style={{ color: '#444', fontSize: `${sm}px` }}>
            {showIcons ? '✉ ' : ''}{data.email}
          </td>
        </tr>
      )}
      {data.website && (
        <tr>
          <td style={{ fontSize: `${sm}px` }}>
            <a href={data.website.startsWith('http') ? data.website : `https://${data.website}`} style={{ color: accent, textDecoration: 'none' }}>
              {showIcons ? '🌐 ' : ''}{data.website}
            </a>
          </td>
        </tr>
      )}
      {addressLine && (
        <tr>
          <td style={{ color: '#444', fontSize: `${sm}px` }}>
            {showIcons ? '📍 ' : ''}{addressLine}
          </td>
        </tr>
      )}
    </>
  );

  const renderCustomFields = () => (
    <>
      {data.customFields.map((f) => (
        <tr key={f.id}>
          <td style={{ color: '#444', fontSize: `${sm}px` }}>
            {f.label}: {f.type === 'link' ? (
              <a href={f.value.startsWith('http') ? f.value : `https://${f.value}`} style={{ color: accent, textDecoration: 'none' }}>{f.value}</a>
            ) : f.value}
          </td>
        </tr>
      ))}
    </>
  );

  const renderLogoRow = (cols: number) => (
    <>
      {style.showLogo && data.companyLogo && (
        <tr>
          <td colSpan={cols} style={{ paddingTop: '12px' }}>
            <img src={data.companyLogo} alt="Logo" height="40" style={{ height: '40px', maxWidth: '200px' }} />
          </td>
        </tr>
      )}
    </>
  );

  const renderModern = () => {
    const cols = (style.showProfileImage && data.profileImage ? 1 : 0) + 1 + (style.includeQR && style.qrUrl ? 1 : 0);
    return (
      <table cellPadding="0" cellSpacing="0" style={{ fontFamily: font, fontSize: `${size}px`, lineHeight: '1.5' }}>
        <tbody>
          <tr>
            {style.showProfileImage && data.profileImage && (
              <td style={{ verticalAlign: 'top', paddingRight: '16px' }}>
                <img src={data.profileImage} alt={data.fullName} width="80" height="80"
                  style={{ borderRadius: '50%', width: '80px', height: '80px', objectFit: 'cover' }} />
              </td>
            )}
            <td style={{ verticalAlign: 'top' }}>
              <table cellPadding="0" cellSpacing="0">
                <tbody>
                  <tr><td><span style={{ fontWeight: 'bold', fontSize: `${lg}px`, color: '#1a1a1a' }}>{data.fullName}</span></td></tr>
                  {data.jobTitle && (
                    <tr><td style={{ color: accent, fontSize: `${size}px`, fontWeight: '600' }}>{data.jobTitle}{data.department ? ` · ${data.department}` : ''}</td></tr>
                  )}
                  {data.company && (
                    <tr><td style={{ color: '#666', fontSize: `${sm}px` }}>{data.company}</td></tr>
                  )}
                  <tr><td style={{ fontSize: '1px', lineHeight: '8px', color: accent }}>▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔</td></tr>
                  {renderContactLines(true)}
                  {renderCustomFields()}
                  {socials.length > 0 && (
                    <tr><td style={{ paddingTop: '4px', fontSize: `${sm}px` }}>{renderSocialLinks()}</td></tr>
                  )}
                </tbody>
              </table>
            </td>
            {style.includeQR && style.qrUrl && (
              <td style={{ verticalAlign: 'top', paddingLeft: '16px' }}>
                <QRCodeSVG value={style.qrUrl} size={64} fgColor={accent} />
              </td>
            )}
          </tr>
          {renderLogoRow(cols)}
        </tbody>
      </table>
    );
  };

  const renderClassic = () => (
    <table cellPadding="0" cellSpacing="0" style={{ fontFamily: font, fontSize: `${size}px`, lineHeight: '1.5' }}>
      <tbody>
        <tr>
          <td style={{ borderLeft: `3px solid ${accent}`, paddingLeft: '12px', verticalAlign: 'top' }}>
            <table cellPadding="0" cellSpacing="0">
              <tbody>
                {style.showProfileImage && data.profileImage && (
                  <tr><td style={{ paddingBottom: '8px' }}>
                    <img src={data.profileImage} alt={data.fullName} width="72" height="72"
                      style={{ borderRadius: '4px', width: '72px', height: '72px', objectFit: 'cover' }} />
                  </td></tr>
                )}
                <tr><td><span style={{ fontWeight: 'bold', fontSize: `${lg}px`, color: '#1a1a1a' }}>{data.fullName}</span></td></tr>
                {data.jobTitle && (
                  <tr><td style={{ color: '#666', fontSize: `${size}px` }}>{data.jobTitle}{data.department ? ` — ${data.department}` : ''}</td></tr>
                )}
                {data.company && (
                  <tr><td style={{ color: accent, fontWeight: '600', fontSize: `${size}px` }}>{data.company}</td></tr>
                )}
                <tr><td style={{ fontSize: `${sm}px`, color: '#555', paddingTop: '6px' }}>
                  {[data.email, data.phone, data.mobile].filter(Boolean).join('  |  ')}
                </td></tr>
                {data.website && (
                  <tr><td style={{ fontSize: `${sm}px` }}>
                    <a href={data.website.startsWith('http') ? data.website : `https://${data.website}`} style={{ color: accent, textDecoration: 'none' }}>{data.website}</a>
                  </td></tr>
                )}
                {addressLine && (
                  <tr><td style={{ color: '#555', fontSize: `${sm}px` }}>{addressLine}</td></tr>
                )}
                {socials.length > 0 && (
                  <tr><td style={{ paddingTop: '4px', fontSize: `${sm}px` }}>{renderSocialLinks(' ')}</td></tr>
                )}
                {renderCustomFields()}
              </tbody>
            </table>
          </td>
          {style.includeQR && style.qrUrl && (
            <td style={{ verticalAlign: 'middle', paddingLeft: '16px' }}>
              <QRCodeSVG value={style.qrUrl} size={64} fgColor={accent} />
            </td>
          )}
        </tr>
        {renderLogoRow(2)}
      </tbody>
    </table>
  );

  const renderMinimal = () => (
    <table cellPadding="0" cellSpacing="0" style={{ fontFamily: font, fontSize: `${size}px`, lineHeight: '1.6' }}>
      <tbody>
        <tr>
          <td>
            <span style={{ fontWeight: '600', color: '#1a1a1a', fontSize: `${size + 2}px` }}>{data.fullName}</span>
            {data.jobTitle && <span style={{ color: accent, marginLeft: '8px' }}>{data.jobTitle}</span>}
          </td>
          {style.includeQR && style.qrUrl && (
            <td rowSpan={2} style={{ verticalAlign: 'top', paddingLeft: '16px' }}>
              <QRCodeSVG value={style.qrUrl} size={56} fgColor={accent} />
            </td>
          )}
        </tr>
        <tr>
          <td style={{ color: '#666', fontSize: `${sm}px` }}>
            {[data.email, data.phone, data.mobile, data.website].filter(Boolean).join(' · ')}
          </td>
        </tr>
      </tbody>
    </table>
  );

  const renderProfessional = () => {
    const cols = (style.showProfileImage && data.profileImage ? 1 : 0) + 1 + (style.includeQR && style.qrUrl ? 1 : 0);
    return (
      <table cellPadding="0" cellSpacing="0" style={{ fontFamily: font, fontSize: `${size}px`, lineHeight: '1.5' }}>
        <tbody>
          <tr>
            {style.showProfileImage && data.profileImage && (
              <td style={{ verticalAlign: 'top', paddingRight: '16px' }}>
                <img src={data.profileImage} alt={data.fullName} width="90" height="90"
                  style={{ borderRadius: '8px', width: '90px', height: '90px', objectFit: 'cover' }} />
              </td>
            )}
            <td style={{ verticalAlign: 'top' }}>
              <table cellPadding="0" cellSpacing="0">
                <tbody>
                  <tr><td><span style={{ fontWeight: 'bold', fontSize: `${size + 5}px`, color: '#1a1a1a' }}>{data.fullName}</span></td></tr>
                  {(data.jobTitle || data.department) && (
                    <tr><td style={{ color: '#666', fontSize: `${size}px` }}>{data.jobTitle}{data.department ? ` — ${data.department}` : ''}</td></tr>
                  )}
                  {data.company && (
                    <tr><td style={{ color: accent, fontWeight: '700', fontSize: `${size + 1}px` }}>{data.company}</td></tr>
                  )}
                  <tr><td style={{ height: '1px', backgroundColor: accent, fontSize: '1px', lineHeight: '1px' }}>&nbsp;</td></tr>
                  {renderContactLines(false)}
                  {socials.length > 0 && (
                    <tr><td style={{ paddingTop: '4px', fontSize: `${sm}px` }}>{renderSocialLinks(' | ')}</td></tr>
                  )}
                  {renderCustomFields()}
                </tbody>
              </table>
            </td>
            {style.includeQR && style.qrUrl && (
              <td style={{ verticalAlign: 'top', paddingLeft: '16px' }}>
                <QRCodeSVG value={style.qrUrl} size={64} fgColor={accent} />
              </td>
            )}
          </tr>
          {renderLogoRow(cols)}
        </tbody>
      </table>
    );
  };

  const renderCreative = () => {
    const cols = 1 + (style.includeQR && style.qrUrl ? 1 : 0) + 1;
    return (
      <table cellPadding="0" cellSpacing="0" style={{ fontFamily: font, fontSize: `${size}px`, lineHeight: '1.5' }}>
        <tbody>
          <tr>
            <td style={{ backgroundColor: accent, width: '4px', borderRadius: '4px' }}>&nbsp;</td>
            <td style={{ paddingLeft: '16px', verticalAlign: 'top' }}>
              <table cellPadding="0" cellSpacing="0">
                <tbody>
                  <tr><td>
                    {style.showProfileImage && data.profileImage ? (
                      <>
                        <img src={data.profileImage} alt={data.fullName} width="60" height="60"
                          style={{ borderRadius: '50%', width: '60px', height: '60px', objectFit: 'cover', marginRight: '12px', verticalAlign: 'middle' }} />
                        <span style={{ fontWeight: 'bold', fontSize: `${lg}px`, color: accent, verticalAlign: 'middle' }}>{data.fullName}</span>
                      </>
                    ) : (
                      <span style={{ fontWeight: 'bold', fontSize: `${lg}px`, color: accent }}>{data.fullName}</span>
                    )}
                  </td></tr>
                  {data.jobTitle && (
                    <tr><td style={{ color: '#555', fontSize: `${size}px`, fontStyle: 'italic' }}>{data.jobTitle}{data.department ? ` · ${data.department}` : ''}</td></tr>
                  )}
                  {data.company && (
                    <tr><td style={{ color: '#333', fontWeight: '600', fontSize: `${size}px` }}>{data.company}</td></tr>
                  )}
                  <tr><td style={{ color: '#555', fontSize: `${sm}px`, paddingTop: '6px' }}>
                    {data.email && <span>✉ {data.email}</span>}
                    {data.email && (data.phone || data.mobile) && <span> &nbsp;·&nbsp; </span>}
                    {data.phone && <span>☎ {data.phone}</span>}
                    {data.phone && data.mobile && <span> &nbsp;·&nbsp; </span>}
                    {data.mobile && <span>📱 {data.mobile}</span>}
                  </td></tr>
                  {data.website && (
                    <tr><td style={{ fontSize: `${sm}px` }}>
                      <a href={data.website.startsWith('http') ? data.website : `https://${data.website}`} style={{ color: accent, textDecoration: 'none' }}>🌐 {data.website}</a>
                    </td></tr>
                  )}
                  {addressLine && (
                    <tr><td style={{ color: '#555', fontSize: `${sm}px` }}>📍 {addressLine}</td></tr>
                  )}
                  {socials.length > 0 && (
                    <tr><td style={{ paddingTop: '4px', fontSize: `${sm}px` }}>{renderSocialLinks(' · ')}</td></tr>
                  )}
                  {renderCustomFields()}
                </tbody>
              </table>
            </td>
            {style.includeQR && style.qrUrl && (
              <td style={{ verticalAlign: 'top', paddingLeft: '16px' }}>
                <QRCodeSVG value={style.qrUrl} size={64} fgColor={accent} />
              </td>
            )}
          </tr>
          {renderLogoRow(cols)}
        </tbody>
      </table>
    );
  };

  const renderCompact = () => (
    <table cellPadding="0" cellSpacing="0" style={{ fontFamily: font, fontSize: `${sm}px`, lineHeight: '1.4' }}>
      <tbody>
        <tr>
          <td>
            <span style={{ fontWeight: 'bold', fontSize: `${size + 1}px`, color: '#1a1a1a' }}>{data.fullName}</span>
            {(data.jobTitle || data.company) && (
              <span style={{ color: '#666' }}>
                {data.jobTitle && ` — ${data.jobTitle}`}{data.company && `, ${data.company}`}
              </span>
            )}
          </td>
          {style.includeQR && style.qrUrl && (
            <td rowSpan={3} style={{ verticalAlign: 'top', paddingLeft: '12px' }}>
              <QRCodeSVG value={style.qrUrl} size={48} fgColor={accent} />
            </td>
          )}
        </tr>
        <tr>
          <td style={{ color: '#555' }}>
            {[data.email, data.phone, data.mobile].filter(Boolean).join(' | ')}
          </td>
        </tr>
        {data.website && (
          <tr>
            <td>
              <a href={data.website.startsWith('http') ? data.website : `https://${data.website}`} style={{ color: accent, textDecoration: 'none' }}>{data.website}</a>
            </td>
          </tr>
        )}
      </tbody>
    </table>
  );

  const templateMap: Record<string, () => React.JSX.Element> = {
    modern: renderModern,
    classic: renderClassic,
    minimal: renderMinimal,
    professional: renderProfessional,
    creative: renderCreative,
    compact: renderCompact,
  };

  return (
    <div style={{ backgroundColor: '#ffffff', padding: '16px', borderRadius: '8px', border: '1px solid #e5e7eb', minWidth: '400px' }}>
      {(templateMap[style.template] || renderModern)()}
    </div>
  );
}