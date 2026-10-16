import { useEffect, useId, useRef, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import {
  ArrowUpRight,
  BookOpen,
  Check,
  ChevronRight,
  ClipboardCheck,
  FileText,
  GraduationCap,
  LoaderCircle,
  Maximize2,
  MessageCircle,
  Minus,
  Send,
  Sparkles,
  X,
} from 'lucide-react';
import { useAuth } from '@/lib/context/AuthContext';
import { supabase } from '@/lib/supabase/client';
import './assistant.css';

type AssistantMessage = {
  id: string;
  role: 'assistant' | 'user';
  text: string;
  action?: { label: string; to: string };
};

type QuickPrompt = {
  label: string;
  prompt: string;
  icon: typeof BookOpen;
};

const PROMPTS: QuickPrompt[] = [
  { label: 'Assignments', prompt: 'Help me find and understand my assignments.', icon: FileText },
  { label: 'Attendance', prompt: 'How can I check my attendance?', icon: ClipboardCheck },
  { label: 'Study materials', prompt: 'Where can I find my study materials?', icon: BookOpen },
  { label: 'LMS help', prompt: 'Help me troubleshoot a common LMS issue.', icon: GraduationCap },
];

const ROUTES: Record<string, string> = {
  assignments: '/portal/assignments',
  attendance: '/portal/attendance',
  materials: '/portal/materials',
  quizzes: '/portal/quizzes',
  curriculum: '/portal/curriculum',
  profile: '/portal/profile',
  feedback: '/portal/feedback',
  notifications: '/portal/notifications',
};

function createId() {
  return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

function assistantRouteFor(role: string, topic: string) {
  const target = topic.toLowerCase();
  if (role === 'admin') {
    if (target.includes('attendance')) return '/attendance';
    if (target.includes('assignment')) return '/assignments';
    if (target.includes('material') || target.includes('resource')) return '/materials';
    if (target.includes('batch')) return '/batches';
    if (target.includes('student')) return '/students';
    if (target.includes('tutor')) return '/tutors';
    if (target.includes('fee') || target.includes('payment')) return '/fees';
    if (target.includes('exam') || target.includes('quiz')) return '/exams';
    if (target.includes('curriculum')) return '/curriculum';
    return '/';
  }
  if (role === 'tutor') {
    if (target.includes('attendance')) return '/tutor/attendance';
    if (target.includes('assignment')) return '/tutor/assignments';
    if (target.includes('material') || target.includes('resource')) return '/tutor/materials';
    if (target.includes('student')) return '/tutor/students';
    if (target.includes('batch')) return '/tutor';
    if (target.includes('exam') || target.includes('quiz')) return '/tutor/exams';
    if (target.includes('curriculum')) return '/tutor/curriculum';
    return '/tutor';
  }
  if (target.includes('material')) return '/portal/materials';
  if (target.includes('assignment')) return '/portal/assignments';
  if (target.includes('attendance')) return '/portal/attendance';
  if (target.includes('quiz') || target.includes('exam')) return '/portal/quizzes';
  if (target.includes('curriculum')) return '/portal/curriculum';
  return ROUTES[target] ?? '/portal';
}

const INITIAL_MESSAGE: AssistantMessage = {
  id: 'welcome',
  role: 'assistant',
  text: 'I can help you navigate Deboistech LMS, understand assignments and attendance, find study materials, and troubleshoot common issues. What can I help you with?',
};

export default function LMSAssistant() {
  const { user, loading } = useAuth();
  const location = useLocation();
  const titleId = useId();
  const panelId = useId();
  const inputId = useId();
  const [open, setOpen] = useState(false);
  const [minimized, setMinimized] = useState(false);
  const [message, setMessage] = useState('');
  const [sending, setSending] = useState(false);
  const [error, setError] = useState('');
  const [responseReadyId, setResponseReadyId] = useState<string | null>(null);
  const [messages, setMessages] = useState<AssistantMessage[]>([INITIAL_MESSAGE]);
  const panelRef = useRef<HTMLElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const messageEndRef = useRef<HTMLDivElement>(null);
  const requestIdRef = useRef(0);

  const role = user?.role ?? 'student';
  const name = user?.full_name?.trim().split(/\s+/)[0] || 'there';
  const mascotSrc = '/favicon.png';

  useEffect(() => {
    if (!open || minimized) return;
    inputRef.current?.focus();
  }, [open, minimized]);

  useEffect(() => {
    if (open && !minimized) {
      messageEndRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' });
    }
  }, [messages, sending, open, minimized]);

  useEffect(() => {
    if (!open) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setOpen(false);
        setMinimized(false);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [open]);

  useEffect(() => () => { requestIdRef.current += 1; }, []);

  if (loading || !user) return null;

  async function sendMessage(rawText: string) {
    const text = rawText.trim();
    if (!text || sending || text.length > 2000) return;

    const userMessage: AssistantMessage = { id: createId(), role: 'user', text };
    const history = messages
      .filter((item) => item.id !== 'welcome')
      .slice(-8)
      .map((item) => ({ role: item.role === 'assistant' ? 'model' : 'user', text: item.text }));

    setMessages((current) => [...current, userMessage]);
    setMessage('');
    setError('');
    setSending(true);
    const requestId = ++requestIdRef.current;

    try {
      // The UI can run before the AI endpoint is deployed. Invoke only the
      // authenticated Edge Function; never call Gemini directly from the browser.
      const { data, error: invokeError } = await supabase.functions.invoke('lms-assistant', {
        body: { message: text, history, pathname: location.pathname },
      });
      if (invokeError) throw invokeError;
      if (typeof data?.answer !== 'string' || !data.answer.trim()) {
        throw new Error(typeof data?.error === 'string' ? data.error : 'No answer was returned.');
      }

      const answer = data.answer.trim();
      const actionLabel = answer.match(/\b(assignments?)\b/i)?.[0]
        ?? answer.match(/\b(attendance)\b/i)?.[0]
        ?? answer.match(/\b(study materials?)\b/i)?.[0]
        ?? answer.match(/\b(quizzes|exams)\b/i)?.[0]
        ?? answer.match(/\b(curriculum)\b/i)?.[0];
      const action = actionLabel
        ? { label: `Open ${actionLabel[0].toUpperCase()}${actionLabel.slice(1)}`, to: assistantRouteFor(role, actionLabel) }
        : undefined;

      if (requestId === requestIdRef.current) {
        const answerMessage: AssistantMessage = { id: createId(), role: 'assistant', text: answer, action };
        setMessages((current) => [...current, answerMessage]);
        setResponseReadyId(answerMessage.id);
      }
    } catch {
      if (requestId === requestIdRef.current) {
        setError('The assistant could not respond. Please try again in a moment.');
      }
    } finally {
      if (requestId === requestIdRef.current) setSending(false);
    }
  }

  function resetConversation() {
    requestIdRef.current += 1;
    setMessages([INITIAL_MESSAGE]);
    setMessage('');
    setError('');
    setSending(false);
    setResponseReadyId(null);
  }

  function handleQuickPrompt(prompt: string) {
    void sendMessage(prompt);
  }

  const roleLabel = role === 'admin' ? 'Administrator support' : role === 'tutor' ? 'Tutor support' : 'Student support';

  return (
    <div className="lms-assistant-root" data-testid="lms-assistant">
      {open && !minimized && (
        <section
          ref={panelRef}
          className="lms-assistant-panel"
          aria-labelledby={titleId}
          aria-label="Deboistech AI Assistant panel"
          id={panelId}
          role="dialog"
          aria-modal="false"
        >
          <header className="lms-assistant-header">
            <div className="lms-assistant-brand">
              <span className="lms-assistant-brand-mark">
                <img src={mascotSrc} alt="" onError={(event) => { event.currentTarget.style.display = 'none'; const fallback = event.currentTarget.nextElementSibling as HTMLElement | null; if (fallback) fallback.style.display = 'block'; }} />
                <Sparkles className="lms-assistant-brand-fallback" size={20} aria-hidden="true" />
              </span>
              <div className="lms-assistant-heading">
                <div className="lms-assistant-title-line">
                  <h2 id={titleId}>Deboistech Assistant</h2>
                  <span className="lms-assistant-beta">AI</span>
                </div>
                <p><span className="lms-assistant-status-dot" /> Online · {roleLabel}</p>
              </div>
            </div>
            <div className="lms-assistant-window-controls">
              <button type="button" className="lms-assistant-icon-button" onClick={() => setMinimized(true)} aria-label="Minimize assistant" title="Minimize">
                <Minus size={17} />
              </button>
              <button type="button" className="lms-assistant-icon-button" onClick={() => { setOpen(false); setMinimized(false); }} aria-label="Close assistant" title="Close">
                <X size={18} />
              </button>
            </div>
          </header>

          <div className="lms-assistant-welcome">
            <div className={`lms-assistant-welcome-mascot ${sending ? 'is-thinking' : ''}`}>
              <img src={mascotSrc} alt="Deboistech green turtle mascot" onError={(event) => { event.currentTarget.style.display = 'none'; }} />
              <span className="lms-assistant-chat-orb" aria-hidden="true"><span /><span /><span /></span>
            </div>
            <div className="lms-assistant-welcome-copy">
              <span className="lms-assistant-eyebrow">YOUR LMS COMPANION</span>
              <h3>Hi {name}, how can I help?</h3>
              <p>Ask me anything about your learning workspace.</p>
            </div>
          </div>

          <div className="lms-assistant-quick-area">
            <p className="lms-assistant-section-label">QUICK HELP</p>
            <div className="lms-assistant-quick-grid">
              {PROMPTS.map(({ label, prompt, icon: Icon }) => (
                <button key={label} type="button" className="lms-assistant-quick-card" onClick={() => handleQuickPrompt(prompt)} disabled={sending}>
                  <span className="lms-assistant-quick-icon"><Icon size={17} /></span>
                  <span>{label}</span>
                  <ChevronRight className="lms-assistant-quick-chevron" size={15} />
                </button>
              ))}
            </div>
          </div>

          <div className="lms-assistant-conversation" aria-live="polite" aria-relevant="additions text">
            <div className="lms-assistant-conversation-label"><span>CONVERSATION</span><span className="lms-assistant-date-divider" /></div>
            {messages.map((item) => (
              <div key={item.id} className={`lms-assistant-message-row is-${item.role} ${item.id === responseReadyId ? 'is-response-ready' : ''}`}>
                {item.role === 'assistant' && (
                  <span className="lms-assistant-message-avatar">
                    <img src={mascotSrc} alt="" onError={(event) => { event.currentTarget.style.display = 'none'; }} />
                    <Sparkles size={14} aria-hidden="true" />
                  </span>
                )}
                <div className={`lms-assistant-message is-${item.role}`}>
                  <p>{item.text}</p>
                  {item.action && (
                    <Link className="lms-assistant-action-link" to={item.action.to} onClick={() => { setOpen(false); setMinimized(false); }}>
                      <span>{item.action.label}</span><ArrowUpRight size={15} />
                    </Link>
                  )}
                  {item.role === 'assistant' && <span className="lms-assistant-message-meta">Deboistech Assistant <Check size={12} /></span>}
                </div>
              </div>
            ))}
            {sending && (
              <div className="lms-assistant-message-row is-assistant">
                <span className="lms-assistant-message-avatar">
                  <img src={mascotSrc} alt="" onError={(event) => { event.currentTarget.style.display = 'none'; const fallback = event.currentTarget.nextElementSibling as HTMLElement | null; if (fallback) fallback.style.display = 'block'; }} />
                  <Sparkles size={14} aria-hidden="true" />
                </span>
                <div className="lms-assistant-thinking" role="status"><LoaderCircle size={15} className="lms-assistant-spinner" /> Thinking through your question<span className="lms-assistant-thinking-dots">...</span></div>
              </div>
            )}
            <div ref={messageEndRef} />
          </div>

          {error && (
            <div className="lms-assistant-error" role="alert">
              <span>{error}</span>
              <button type="button" onClick={() => { const latest = [...messages].reverse().find((item) => item.role === 'user'); if (latest) void sendMessage(latest.text); }}>Try again</button>
            </div>
          )}

          <form className="lms-assistant-composer" onSubmit={(event) => { event.preventDefault(); void sendMessage(message); }}>
            <label className="sr-only" htmlFor={inputId}>Message the Deboistech Assistant</label>
            <input
              ref={inputRef}
              id={inputId}
              value={message}
              onChange={(event) => setMessage(event.target.value)}
              placeholder="Ask anything about Deboistech LMS..."
              maxLength={2000}
              disabled={sending}
              autoComplete="off"
            />
            <span className="lms-assistant-composer-divider" aria-hidden="true" />
            <button type="submit" disabled={sending || !message.trim()} aria-label="Send message" className="lms-assistant-send-button">
              {sending ? <LoaderCircle size={18} className="lms-assistant-spinner" /> : <Send size={17} />}
            </button>
          </form>
          <footer className="lms-assistant-footer">
            <Sparkles size={12} aria-hidden="true" />
            <span>AI can make mistakes. Verify important information with your tutor or administrator.</span>
            <button type="button" onClick={resetConversation} title="Start a new conversation" aria-label="Start a new conversation"><MessageCircle size={14} /></button>
          </footer>
        </section>
      )}

      {open && minimized && (
        <button type="button" className="lms-assistant-minimized" onClick={() => setMinimized(false)}>
          <img src={mascotSrc} alt="" onError={(event) => { event.currentTarget.style.display = 'none'; }} />
          <span>Assistant is minimized</span>
          <Maximize2 size={15} />
        </button>
      )}

      <button
        type="button"
        className={`lms-assistant-launcher ${open ? 'is-open' : ''}`}
        onClick={() => { setOpen((current) => !current); setMinimized(false); }}
        aria-label={open ? 'Close Deboistech Assistant' : 'Open Deboistech Assistant'}
        aria-expanded={open}
        aria-controls={panelId}
      >
        <span className="lms-assistant-launcher-ring" aria-hidden="true" />
        {open ? (
          <X className="lms-assistant-launcher-close-icon" size={23} aria-hidden="true" />
        ) : (
          <>
            <img src={mascotSrc} alt="" onError={(event) => { event.currentTarget.style.display = 'none'; const fallback = event.currentTarget.nextElementSibling as HTMLElement | null; if (fallback) fallback.style.display = 'block'; }} />
            <Sparkles className="lms-assistant-launcher-fallback" size={23} aria-hidden="true" />
          </>
        )}
        <span className="lms-assistant-launcher-status" aria-hidden="true" />
      </button>
    </div>
  );
}
