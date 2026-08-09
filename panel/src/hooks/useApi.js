import { useCallback, useEffect, useRef, useState } from 'react';

/**
 * Busca dados com estados de loading/erro e recarga manual.
 *
 * `deps` controla quando refazer a chamada (filtros, pagina...). O `seq`
 * descarta respostas de requisicoes antigas que chegarem fora de ordem.
 */
export function useApi(fetcher, deps = []) {
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);

  const seq = useRef(0);
  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;

  const run = useCallback(async () => {
    const current = ++seq.current;
    setLoading(true);
    setError(null);

    try {
      const result = await fetcherRef.current();
      if (current === seq.current) setData(result);
    } catch (err) {
      if (current === seq.current) setError(err);
    } finally {
      if (current === seq.current) setLoading(false);
    }
  }, []);

  useEffect(() => {
    run();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  return { data, error, loading, reload: run, setData };
}

/** Debounce para o campo de busca das listagens. */
export function useDebounced(value, delay = 400) {
  const [debounced, setDebounced] = useState(value);

  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delay);
    return () => clearTimeout(timer);
  }, [value, delay]);

  return debounced;
}
