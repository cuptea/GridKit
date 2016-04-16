begin;
drop function if exists fair_division(n int, d int);
drop function if exists array_mult(n int array, int);
drop function if exists array_slice(anyarray, int, int);

create function fair_division (n int, d int) returns int array as $$
begin
    return array_cat(array_fill( n / d + 1, array[n % d]), array_fill( n / d, array[d - n % d]));
end;
$$ language plpgsql;

create function array_mult(n int array, x int) returns int array as $$
begin
    return array(select v*x from unnest(n) v);
end;
$$ language plpgsql;

create function array_slice(n anyarray, low int, high int) returns anyarray as $$
begin
    return array(select v from (select unnest(n), generate_subscripts(n, 1)) f(v,i) where i between low and high);
end;
$$ language plpgsql;



drop table if exists divisible_cables;
create table divisible_cables (
    osm_name varchar(64) primary key,
    num_lines integer,
    total_cables integer,
    cables integer array
);

insert into divisible_cables (osm_name, num_lines, total_cables)
    select osm_name, case when array_length(voltage, 1) > 1 then array_length(voltage, 1)
                          else array_length(frequency, 1) end, cables[1]
        from electric_tags e
        where exists (select 1 from power_type_names t where t.power_name = e.power_name and t.power_type = 'l')
          and (array_length(voltage, 1) > 1 or array_length(frequency, 1) > 1) and array_length(cables, 1) = 1
          and cables[1] > 4;


update divisible_cables
     set cables = case when total_cables >= num_lines * 3 and total_cables % 3 = 0 then array_mult(fair_division(total_cables / 3, num_lines), 3)
                       when total_cables >= num_lines * 4 and total_cables % 4 = 0 then array_mult(fair_division(total_cables / 4, num_lines), 4)
                       when total_cables >= 7 and (total_cables - 4) % 3 = 0 then array_cat(array[4],  array_mult(fair_division((total_cables - 4) / 3, num_lines - 1), 3))
                       when total_cables >= 11 and (total_cables - 8) % 3 = 0 then array_cat(array[8], array_mult(fair_division((total_cables - 8) / 3, num_lines-1), 3))
                       else array[total_cables] end;

-- can't seem to solve this one analytically...
update divisible_cables set cables = array[4,4,3] where total_cables = 11 and num_lines = 3;

update electric_tags e set cables = d.cables from divisible_cables d where d.osm_name = e.osm_name;

-- fix 16.67 Hz to 16.7 frequency for consistency.
update electric_tags e
   set frequency = array_replace(frequency::numeric[],16.67,16.7)
   where 16.67 = any(frequency);

-- fix inconsistently striped lines

drop table if exists inconsistent_line_tags;
create table inconsistent_line_tags (
    osm_name varchar(64) primary key,
    voltage integer array,
    frequency float array,
    cables integer array,
    wires integer array
);

-- this affects surprisingly few lines, actually
insert into inconsistent_line_tags (osm_name, voltage, frequency, cables, wires)
   select osm_name, voltage, frequency, cables, wires from electric_tags e
       where exists (select 1 from power_type_names t where t.power_name = e.power_name and t.power_type = 'l')
        and (array_length(voltage, 1) >= 3
             and (array_length(frequency, 1) > 1 and array_length(frequency, 1) < array_length(voltage, 1) or
                  array_length(cables, 1) > 1 and array_length(cables, 1) < array_length(voltage, 1) or
                  array_length(wires, 1) > 1 and array_length(wires, 1) < array_length(voltage, 1))

          or array_length(frequency, 1) >= 3
             and (array_length(voltage, 1) > 1 and array_length(voltage, 1) < array_length(frequency, 1) or
                  array_length(cables, 1) > 1 and array_length(cables, 1) < array_length(frequency, 1) or
                  array_length(wires, 1) > 1 and array_length(wires, 1) < array_length(frequency, 1))

          or array_length(cables, 1) >= 3
             and (array_length(voltage, 1) > 1 and array_length(voltage, 1) < array_length(cables, 1) or
                  array_length(frequency, 1) > 1 and array_length(frequency, 1) < array_length(cables, 1) or
                  array_length(wires, 1) > 1 and array_length(wires, 1) < array_length(cables, 1))

          or array_length(wires, 1) >= 3
             and (array_length(voltage, 1) > 1 and array_length(voltage, 1) < array_length(wires, 1) or
                  array_length(frequency, 1) > 1 and array_length(frequency, 1) < array_length(wires, 1) or
                  array_length(cables, 1) > 1 and array_length(cables, 1) < array_length(wires, 1)));

-- patch cables and wires
-- default cables is 3, default wires is 1
update inconsistent_line_tags set cables = array_cat(cables, array_fill(3, array[array_length(voltage,1) - array_length(cables, 1)]))
    where array_length(voltage, 1) > array_length(cables, 1) and array_length(cables, 1) > 1;

update inconsistent_line_tags set wires = array_cat(wires, array_fill(1, array[array_length(voltage,1) - array_length(wires, 1)]))
    where array_length(voltage, 1) > array_length(wires, 1) and array_length(wires, 1) > 1;

-- default frequency is 50, prepend it to assign it to the highest voltage.. thats just a random guess, but who knows better?
update inconsistent_line_tags set frequency = array_cat(array_fill(50.0, array[array_length(voltage, 1) - array_length(frequency, 1)])::float[], frequency)
    where array_length(voltage, 1) > array_length(frequency, 1) and array_length(frequency, 1) > 1;

-- peel of excess wires
update inconsistent_line_tags set wires = array_slice(wires, 1, array_length(voltage, 1))
    where array_length(wires, 1) > array_length(voltage, 1) and array_length(voltage, 1) > 1;

-- that's enough! for now at least
update electric_tags e set frequency = i.frequency, cables = i.cables, wires = i.wires  from inconsistent_line_tags i where e.osm_name = i.osm_name;

commit;
