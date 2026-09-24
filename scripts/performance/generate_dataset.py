"""Deterministic, fully synthetic CSV fixtures. Never reads application data or credentials."""
import argparse, csv, hashlib, json, math, random, shutil, time
from datetime import date, timedelta
from pathlib import Path

DATASET_ID = 'rc-perf-20260921-v1'
DEPOTS, CAMPAIGNS, CUSTOMERS = 100, 1000, 100000
ANCHOR = date(2026, 9, 21)

def uid(kind, n):
    return f'{kind:08x}-0000-4000-8000-{n:012x}'

def depot_for(customer):
    # Reproducible skew: roughly 32% of customers in the busiest 10% of depots.
    u = ((customer * 2654435761) % 2**32) / 2**32
    return 1 + min(DEPOTS-1, int(u*u*DEPOTS))

def claim_status(n):
    b = ((n * 2654435761) % 2**32) % 100
    return 'not_yet' if b<30 else 'submitted' if b<45 else 'released' if b<60 else 'claimed' if b<70 else 'done' if b<95 else 'on_hold' if b<98 else 'expired'

def generate(out, rows=1000000):
    out=Path(out)
    if not 1<=rows<=1000000: raise ValueError('Use 1..1,000,000 rows')
    if out.exists(): raise ValueError('Output already exists; use a new directory')
    out.parent.mkdir(parents=True,exist_ok=True)
    if shutil.disk_usage(out.parent).free < max(rows*800,10_000_000): raise ValueError('Insufficient disk space')
    out.mkdir()
    start=time.monotonic(); files=[]; customers=min(CUSTOMERS,rows); statuses={}; depots={}
    def write(name,headers,records):
        p=out/(name+'.csv'); count=0
        with p.open('w',newline='',encoding='utf-8') as f:
            w=csv.writer(f);w.writerow(headers)
            for record in records:w.writerow(record);count+=1
        digest=hashlib.sha256()
        with p.open('rb') as f:
            for chunk in iter(lambda:f.read(1024*1024),b''):digest.update(chunk)
        files.append(dict(file=p.name,rows=count,bytes=p.stat().st_size,sha256=digest.hexdigest(),columns=headers))
    write('depots',['id','depot_code','depot_name','region','abbr'],
          ((uid(1,i),f'PERFD{i:03}',f'Dummy Depot {i}',f'REGION{(i-1)//20+1}',f'P{i:03}') for i in range(1,DEPOTS+1)))
    def campaigns():
        for i in range(1,CAMPAIGNS+1):
            begin=ANCHOR-timedelta(days=(i%24)*30+90);end=begin+timedelta(days=89)
            yield [uid(2,i),f'PERFC{i:04}',f'Dummy Campaign {i}',begin,end,'Transfer','Customer','active']
    write('campaigns',['id','campaign_code','campaign_name','period_start','period_end','cashback_type','tax_status','status'],campaigns())
    shop_names=['Toko','Mitra','Sumber','Jaya']
    write('customers',['id','customer_code','customer_name','tax_subject','top_text','bank','account_number','account_name'],
          ((uid(3,i),f'PERFU{i:06}',f'Dummy {shop_names[i%4]} {i}','Badan','30','DUMMY BANK',f'DUMMY-ACCOUNT-{i:06}',f'Dummy Owner {i}') for i in range(1,customers+1)))
    write('customer_depots',['customer_id','depot_id'],((uid(3,i),uid(1,depot_for(i))) for i in range(1,customers+1)))
    def claims():
        rng=random.Random(20260921)
        for n in range(1,rows+1):
            customer=(n-1)%customers+1; depot=depot_for(customer)
            campaign=((customer*37+(n-1)//customers*13)%CAMPAIGNS)+1
            begin=ANCHOR-timedelta(days=(campaign%24)*30+90);end=begin+timedelta(days=89)
            created=end+timedelta(days=1+n%10);s=claim_status(n)
            depth={'not_yet':0,'submitted':1,'released':2,'claimed':3,'done':4,'on_hold':2,'expired':1}[s]
            stages={'not_yet':0,'submitted':1,'released':2,'claimed':3,'done':4,'on_hold':1,'expired':0}[s]
            value=round(min(500_000_000,math.exp(rng.gauss(12.0,1.5)))*100)
            money=f'{value//100}.{value%100:02}'
            statuses[s]=statuses.get(s,0)+1;depots[str(depot)]=depots.get(str(depot),0)+1
            dates=[str(created+timedelta(days=i))+'T08:00:00Z' if stages>=i else '' for i in range(1,5)]
            batch=[f'{i:02}000{created:%d%m%y}{1+(n//100)%9999:04}' if stages>=i else '' for i in range(1,5)]
            yield [uid(4,n),f'PERF/{n:09}',uid(2,campaign),uid(3,customer),uid(1,depot),s,
                   'submitted' if s=='on_hold' else '',money,money,1,'Badan',begin,end,
                   str(created)+'T08:00:00Z',str(created+timedelta(days=depth))+'T08:00:00Z',depth+1,*dates,*batch]
    write('claims',['id','no_doc','campaign_id','customer_id','depot_id','status','previous_status','cb_net','net_value','volume','tax_subject','period_start','period_end','created_at','updated_at','version_no','uploaded_at','released_at','claimed_at','cleared_at','batch_upload','batch_release','batch_claim','batch_clearing'],claims())
    manifest=dict(dataset_id=DATASET_ID,kind='OFFLINE_DUMMY_CSV_NOT_DATABASE',seed=20260921,claim_rows=rows,
                  depot_rows=DEPOTS,campaign_rows=CAMPAIGNS,customer_rows=customers,status_distribution=statuses,
                  depot_distribution=depots,files=files,elapsed_seconds=round(time.monotonic()-start,3))
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    return manifest

def verify(out):
    out=Path(out);m=json.loads((out/'manifest.json').read_text());total=0
    for info in m['files']:
        p=out/info['file'];h=hashlib.sha256()
        with p.open('rb') as f:
            for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
        if h.hexdigest()!=info['sha256']:raise ValueError('Checksum mismatch: '+p.name)
        with p.open(newline='',encoding='utf-8') as f:
            r=csv.DictReader(f);count=0
            for row in r:
                count+=1
                if p.name=='claims.csv':
                    customer=(count-1)%m['customer_rows']+1
                    campaign=((customer*37+(count-1)//m['customer_rows']*13)%CAMPAIGNS)+1
                    if row['id']!=uid(4,count) or row['no_doc']!=f'PERF/{count:09}':raise ValueError('Claim identity mismatch')
                    if row['customer_id']!=uid(3,customer) or row['depot_id']!=uid(1,depot_for(customer)) or row['campaign_id']!=uid(2,campaign):raise ValueError('Claim relationship mismatch')
                    if row['status']!=claim_status(count) or row['period_end']<row['period_start']:raise ValueError('Invalid status/date')
            if count!=info['rows']:raise ValueError('Row count mismatch')
            total+=count
    return {'status':'PASS_OFFLINE_CSV','claim_rows':m['claim_rows'],'all_csv_rows':total,'files_verified':len(m['files'])}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out',required=True);p.add_argument('--rows',type=int,default=1000000);p.add_argument('--verify',action='store_true');a=p.parse_args()
    print(json.dumps(verify(a.out) if a.verify else generate(a.out,a.rows),indent=2))
