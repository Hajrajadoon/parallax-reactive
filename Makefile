.PHONY: setup build test deploy whale status dashboard clean

setup:        ## install deps, build, test
	./scripts/setup.sh

build:
	forge build

test:
	forge test -vv

deploy:       ## deploy the whole loop to Unichain Sepolia + Base Sepolia + Reactive Lasna
	./scripts/deploy-all.sh

whale:        ## make whale SIDE=base DIR=dump AMT=8
	./scripts/whale.sh $(or $(SIDE),base) $(or $(DIR),dump) $(or $(AMT),8)

status:
	./scripts/status.sh

dashboard:    ## serve landing page + dashboard on http://localhost:8090 (dashboard at /app.html)
	./scripts/write-dashboard-config.sh
	cd dashboard && python3 -m http.server 8090

clean:
	forge clean
