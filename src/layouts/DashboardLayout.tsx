import { useState, useEffect } from 'react';
import { Outlet, useLocation } from 'react-router-dom';
import { Navbar } from '@/components/layout/Navbar';
import { Sidebar } from '@/components/layout/Sidebar';
import LMSAssistant from '@/components/assistant/LMSAssistant';

export default function DashboardLayout() {
  const { pathname } = useLocation();
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);

  useEffect(() => {
    document.body.style.overflow = sidebarOpen ? 'hidden' : '';
    return () => { document.body.style.overflow = ''; };
  }, [sidebarOpen]);

  const handleSidebarToggle = () => {
    if (window.innerWidth < 1024) {
      setSidebarCollapsed(false);
      setSidebarOpen((open) => !open);
      return;
    }
    setSidebarCollapsed((collapsed) => !collapsed);
  };

  return (
    <div className="min-h-screen bg-[var(--bg-base)]">
      <Navbar
        onMenuClick={() => {
          setSidebarCollapsed(false);
          setSidebarOpen(true);
        }}
      />
      <div className="app-shell">
        <Sidebar
          open={sidebarOpen}
          collapsed={sidebarCollapsed}
          onClose={() => setSidebarOpen(false)}
          onToggle={handleSidebarToggle}
        />
        <main key={pathname} className="app-content animate-fade-in">
          <Outlet />
        </main>
      </div>
      <LMSAssistant />
    </div>
  );
}
