import { useState, useEffect } from 'react';
import { Outlet, useLocation } from 'react-router-dom';
import { LayoutDashboard, Users, ClipboardCheck, FileText, BookOpen, LibraryBig, ClipboardList } from 'lucide-react';
import { Navbar } from '@/components/layout/Navbar';
import { Sidebar } from '@/components/layout/Sidebar';
import LMSAssistant from '@/components/assistant/LMSAssistant';

const TUTOR_NAV_ITEMS = [
  { label: 'Dashboard', to: '/tutor', icon: LayoutDashboard, end: true },
  { label: 'Students', to: '/tutor/students', icon: Users },
  { label: 'Attendance', to: '/tutor/attendance', icon: ClipboardCheck },
  { label: 'Assignments', to: '/tutor/assignments', icon: FileText },
  { label: 'Curriculum', to: '/tutor/curriculum', icon: LibraryBig },
  { label: 'Exams', to: '/tutor/exams', icon: ClipboardList },
  { label: 'Study Material', to: '/tutor/materials', icon: BookOpen },
];

export default function TutorLayout() {
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
        homePath="/tutor"
        themeToggle
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
          items={TUTOR_NAV_ITEMS}
          newAction={null}
        />
        <main key={pathname} className="app-content animate-fade-in">
          <Outlet />
        </main>
      </div>
      <LMSAssistant />
    </div>
  );
}
