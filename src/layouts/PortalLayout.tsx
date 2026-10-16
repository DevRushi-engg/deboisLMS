import { useEffect, useRef, useState } from 'react';
import { Outlet, useLocation, useNavigate } from 'react-router-dom';
import { ChevronDown, LogOut, Menu, Moon, Sun } from 'lucide-react';
import { PortalNav } from '@/components/layout/PortalNav';
import { MaintenancePage } from '@/components/portal';
import { NotificationBell } from '@/components/notifications/NotificationBell';
import { useAuth } from '@/lib/context/AuthContext';
import { useTheme } from '@/lib/context/ThemeContext';
import { supabase } from '@/lib/supabase/client';
import { getMaintenanceMode } from '@/lib/supabase';
import { InlineAlert } from '@/components/ui/InlineAlert';
import { Spinner } from '@/components/ui/Spinner';
import { PortalBatchProvider, usePortalBatch } from '@/lib/context/PortalBatchContext';
import { useNow } from '@/lib/hooks/useNow';
import { formatDate } from '@/lib/utils/format';
import LMSAssistant from '@/components/assistant/LMSAssistant';

// Re-mounts when the page or the chosen batch changes, so every page loads that batch's data
function PortalMain() {
  const { pathname } = useLocation();
  const { batchId, expiresOn } = usePortalBatch();
  const now = useNow();
  const daysLeft = expiresOn ? Math.ceil((new Date(expiresOn).getTime() - now) / 86_400_000) : null;

  return (
    <main key={`${pathname}:${batchId}`} className="portal-main animate-fade-in">
      {expiresOn && daysLeft !== null && daysLeft <= 14 && (
        <InlineAlert>Download your documents before {formatDate(expiresOn)}</InlineAlert>
      )}
      <Outlet />
    </main>
  );
}

export default function PortalLayout() {
  const { user } = useAuth();
  const { theme, toggle } = useTheme();
  const navigate = useNavigate();
  const [menuOpen, setMenuOpen] = useState(false);
  const [navOpen, setNavOpen] = useState(false);
  const [maintenance, setMaintenance] = useState<boolean | null>(null);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    getMaintenanceMode().then(setMaintenance).catch(() => setMaintenance(false));
  }, []);

  useEffect(() => {
    const handler = (event: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(event.target as Node)) setMenuOpen(false);
    };
    if (menuOpen) document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [menuOpen]);

  const initials = user?.full_name
    .split(' ')
    .map((word) => word[0])
    .slice(0, 2)
    .join('')
    .toUpperCase() ?? '?';

  if (maintenance === null) return <Spinner centered />;
  if (maintenance) {
    return <MaintenancePage onRetry={async () => setMaintenance(await getMaintenanceMode())} />;
  }

  return (
    <PortalBatchProvider>
    <div className="min-h-screen bg-[var(--bg-base)]">
      <header className="portal-topbar">
        <div className="flex min-w-0 items-center gap-2">
          <button
            type="button"
            onClick={() => setNavOpen(true)}
            className="portal-menu-button"
            aria-label="Open menu"
            aria-expanded={navOpen}
            aria-controls="portal-menu"
          >
            <Menu size={18} />
          </button>
          <img
            src={theme === 'dark' ? '/logo-dark.png' : '/logo.png'}
            alt="Deboistech"
            className="h-8 w-auto select-none"
          />
        </div>

        <div className="flex items-center gap-1">
        <NotificationBell />
        <div className="relative" ref={menuRef}>
          <button
            onClick={() => setMenuOpen((open) => !open)}
            className="flex items-center gap-2.5 rounded-[var(--radius-md)] px-2 py-1.5 transition-colors hover:bg-[var(--bg-elevated)]"
          >
            <span className="flex h-8 w-8 items-center justify-center rounded-full bg-[var(--primary-glow-soft)] text-xs font-bold text-[var(--primary)]">
              {initials}
            </span>
            <span className="hidden max-w-[9rem] truncate text-sm font-semibold text-[var(--text-primary)] sm:block">
              {user?.full_name}
            </span>
            <ChevronDown size={14} className="shrink-0 text-[var(--text-muted)]" />
          </button>

          {menuOpen && (
            <div className="nav-user-dropdown absolute right-0 top-full z-50 mt-2 min-w-[220px] animate-dropdown rounded-[var(--radius-sm)] border border-[var(--border)] bg-[var(--bg-elevated)] shadow-[var(--shadow-lg)]">
              <div className="nav-user-dropdown-header border-b border-[var(--border)]">
                <p className="text-sm font-semibold text-[var(--text-primary)]">{user?.full_name}</p>
                <p className="mt-1 text-xs text-[var(--text-muted)]">{user?.email}</p>
              </div>

              <button
                onClick={toggle}
                className="nav-user-dropdown-item flex w-full items-center justify-between text-sm text-[var(--text-primary)] transition-colors hover:bg-[var(--bg-overlay)]"
              >
                <span className="flex items-center gap-3">
                  {theme === 'dark' ? <Moon size={17} /> : <Sun size={17} />}
                  <span>Theme</span>
                </span>
                <span
                  className={`relative h-[24px] w-[44px] rounded-full transition-colors duration-200 ${theme === 'dark' ? 'bg-[var(--primary)]' : 'bg-[var(--text-muted)]'}`}
                >
                  <span
                    className={`absolute left-[3px] top-[3px] h-[18px] w-[18px] rounded-full bg-white transition-transform duration-200 ${theme === 'dark' ? 'translate-x-5' : 'translate-x-0'}`}
                  />
                </span>
              </button>

              <div className="nav-user-dropdown-divider border-t border-[var(--border)]">
                <button
                  onClick={async () => {
                    await supabase.auth.signOut();
                    navigate('/auth/login');
                  }}
                  className="nav-user-dropdown-item flex w-full items-center gap-3 text-sm text-red-400 transition-colors hover:bg-red-500/10"
                >
                  <LogOut size={16} />
                  Sign Out
                </button>
              </div>
            </div>
          )}
        </div>
        </div>
      </header>

      <PortalNav open={navOpen} onClose={() => setNavOpen(false)} />

      <PortalMain />
      <LMSAssistant />
    </div>
    </PortalBatchProvider>
  );
}
