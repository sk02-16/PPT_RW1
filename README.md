text plz here 



---------------------------------------------------------------------------
  -- Period measurement between sector changes (edge-to-edge)
  ---------------------------------------------------------------------------
  process(clk, rst_n)
    variable per : unsigned(31 downto 0);
  begin
    if rst_n = '0' then
      t_last_edge   <= (others=>'0');
      period_counts <= (others=>'0');
      period_valid  <= '0';
      valid_i       <= '0';
    elsif rising_edge(clk) then
      if sector_change = '1' and sector_cur /= "111" then
        per := tick_counter - t_last_edge;
        t_last_edge   <= tick_counter;
        -- Simple clamp to avoid div-by-zero and ridiculous values
        if per = (others=>'0') then
          period_counts <= to_unsigned(1,32);
        else
          period_counts <= per;
        end if;
        period_valid  <= '1';
        valid_i       <= '1';
      else
        period_valid  <= '0';
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Instantaneous RPM = (KdivP) / period_counts, KdivP=(Fclk*10)/P => equals (Fclk*60)/(6*P)
  -- Then EMA filter: rpm_filt += (rpm_inst - rpm_filt)/2^RPM_EMA_SHIFT
  ---------------------------------------------------------------------------
  process(clk, rst_n)
    variable div_q : unsigned(31 downto 0);
    constant K_CONST : unsigned(31 downto 0) := to_unsigned(KdivP,32);
    variable diff   : signed(32 downto 0);
  begin
    if rst_n = '0' then
      rpm_inst <= (others=>'0');
      rpm_filt <= (others=>'0');
    elsif rising_edge(clk) then
      if period_valid = '1' then
        -- Unsigned division; synthesizable in most tools (or replace with divider IP if needed)
        div_q := K_CONST / period_counts;
        rpm_inst <= div_q;

        -- EMA filtering (signed math to handle diff)
        diff := signed(('0' & rpm_inst)) - signed(('0' & rpm_filt));
        rpm_filt <= unsigned( signed(rpm_filt) + (diff sra RPM_EMA_SHIFT) );
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Angle interpolation: within each 60° sector, fraction = ticks_since / period_counts
  -- Electrical angle Q10 = sector*1024 + frac*1024, wrap to 0..6143
  ---------------------------------------------------------------------------
  process(clk, rst_n)
    variable base_q10 : unsigned(12 downto 0);
    variable frac_q10 : unsigned(12 downto 0);
    variable num      : unsigned(31 downto 0);
    variable q        : unsigned(31 downto 0);
    variable s_i      : integer;
  begin
    if rst_n = '0' then
      ticks_since <= (others=>'0');
      elec_q10_i  <= (others=>'0');
    elsif rising_edge(clk) then
      -- ticks since last edge
      ticks_since <= tick_counter - t_last_edge;

      -- Compute only if sector is valid and we have a nonzero period
      s_i := SECTOR_LUT(to_integer(hall_code));
      if (s_i /= -1) and (period_counts /= to_unsigned(0,32)) then
        base_q10 := to_unsigned(s_i*1024, 13);
        -- frac_q10 = (ticks_since * 1024) / period_counts
        num := ticks_since * to_unsigned(1024,32);
        q   := num / period_counts; -- 0..1024
        if q > to_unsigned(1023,32) then
          q := to_unsigned(1023,32); -- clamp
        end if;
        frac_q10 := resize(q, 13);
        elec_q10_i <= base_q10 + frac_q10; -- auto wraps at sector boundary
      end if;
    end if;
  end process;

  -- Drive outputs
  sector   <= sector_cur;
  dir_ccw  <= dir_ccw_i;
  elec_q10 <= elec_q10_i;
  rpm      <= rpm_filt;
  valid    <= valid_i;

end architecture;
